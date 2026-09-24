// What the feed needs from iOS that dartnative_video_player 1.0.1 does not
// expose: background audio, Picture in Picture, the lock-screen / Control
// Center player, and an AirPlay route picker placed in the Dart layout.
//
// The video plugin owns its AVPlayer and gives Dart only a pointer to the view
// it draws into (`VideoPlayerController.nativeViewPtr`). Everything here starts
// from that pointer: find the AVPlayerLayer under it, take its player, and use
// public AVFoundation / AVKit / MediaPlayer API on them.
//
// Wiring follows docs/plugin_development.md: @_cdecl entry points looked up
// from Dart with DynamicLibrary.process(), a claimed ViewType for the one
// native view, and the dispatcher slot for every call back into Dart.

import AVFoundation
import AVKit
import MediaPlayer
import UIKit

private func log(_ msg: String) { print("[FeedNativeMedia] \(msg)") }

// MARK: - Calling Dart (dispatcher slot, plugin_async_callbacks.md)

/// Event types sent to Dart. Must match `_Event` in feed_native_media.dart.
private enum Event: Int32 {
    case remoteNext = 1
    case remotePrevious = 2
    case remotePlay = 3
    case remotePause = 4
    case pipStarted = 5
    case pipStopped = 6
    case externalPlayback = 7   // payload "1" / "0"
    case remoteSeek = 8         // payload: milliseconds
    case pipFailed = 9          // payload: error
    case refresh = 10           // the user pulled to refresh
}

private let dispatcherSlot: UnsafeMutablePointer<Int64> = {
    let p = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    p.pointee = 0
    return p
}()
private var slotRegistered = false

@_cdecl("FNMSetDispatcher")
public func FNMSetDispatcher(_ callbackPtr: Int64) {
    dispatcherSlot.pointee = callbackPtr
    guard !slotRegistered else { return }
    slotRegistered = true
    typealias RegFn = @convention(c) (UnsafeMutablePointer<Int64>) -> Void
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DNRegisterAsyncDispatcherSlot") {
        unsafeBitCast(sym, to: RegFn.self)(dispatcherSlot)
    } else {
        log("DNRegisterAsyncDispatcherSlot not found")
    }
}

private typealias Dispatch = @convention(c) (Int64, Int32, UnsafePointer<CChar>) -> Void

private func fire(_ event: Event, _ payload: String = "") {
    let send = {
        let addr = dispatcherSlot.pointee   // read fresh every time
        guard addr != 0 else { return }     // hot restart: drop
        payload.withCString { unsafeBitCast(addr, to: Dispatch.self)(0, event.rawValue, $0) }
    }
    if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
}

// MARK: - Finding the player

private func playerLayer(in layer: CALayer) -> AVPlayerLayer? {
    if let l = layer as? AVPlayerLayer { return l }
    for sub in layer.sublayers ?? [] {
        if let l = playerLayer(in: sub) { return l }
    }
    return nil
}

private func view(fromPointer ptr: Int64) -> UIView? {
    guard ptr != 0, let raw = UnsafeRawPointer(bitPattern: Int(ptr)) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? UIView
}

// MARK: - The media session

private final class MediaSession: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = MediaSession()

    weak var layer: AVPlayerLayer?
    weak var player: AVPlayer?
    var pip: AVPictureInPictureController?
    var backgroundEnabled = true
    /// The layer's player, held while it is detached for background audio.
    var detached: (AVPlayerLayer, AVPlayer)?
    var configured = false
    var nowPlaying: [String: Any] = [:]
    var routeObserver: NSObjectProtocol?

    func configure() -> Int32 {
        if configured { return 1 }
        do {
            // .playback is what lets audio continue with the screen locked or
            // the app in the background, and what PiP requires.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log("audio session: \(error)")
            return -1
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        routeObserver = nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            self?.reportExternal()
        }
        registerRemoteCommands()
        configured = true
        return 1
    }

    // Lock screen, Control Center, headphones, CarPlay.
    private func registerRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { _ in fire(.remotePlay); return .success }
        rc.pauseCommand.addTarget { _ in fire(.remotePause); return .success }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in
            fire((self?.player?.rate ?? 0) > 0 ? .remotePause : .remotePlay)
            return .success
        }
        rc.nextTrackCommand.addTarget { _ in fire(.remoteNext); return .success }
        rc.previousTrackCommand.addTarget { _ in fire(.remotePrevious); return .success }
        rc.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            fire(.remoteSeek, String(Int(e.positionTime * 1000)))
            return .success
        }
        for c in [rc.playCommand, rc.pauseCommand, rc.togglePlayPauseCommand,
                  rc.nextTrackCommand, rc.previousTrackCommand,
                  rc.changePlaybackPositionCommand] {
            c.isEnabled = true
        }
    }

    /// Point everything at the player drawing into `view`. Returns 1 when
    /// attached, -1 with no view, -2 with no AVPlayerLayer under it yet (the
    /// plugin has not built it; retry after the next frame), -3 with no player.
    func attach(view: UIView?, title: String, artist: String, durationMs: Int64) -> Int32 {
        guard let view else { return -1 }
        guard let l = playerLayer(in: view.layer) else { return -2 }
        guard let p = l.player else { return -3 }

        if layer !== l {
            // A previous layer that was detached for the background gets its
            // player back before we move on.
            restoreDetached()
            layer = l
            // Each layer needs its own PiP controller.
            if AVPictureInPictureController.isPictureInPictureSupported() {
                let c = AVPictureInPictureController(playerLayer: l)
                c?.delegate = self
                // Swiping home while playing floats the video, like Safari.
                c?.canStartPictureInPictureAutomaticallyFromInline = true
                pip = c
            }
        }
        player = p
        // Default true already; stated so AirPlay sends video, not only audio.
        p.allowsExternalPlayback = true
        p.usesExternalPlaybackWhileExternalScreenIsActive = true

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000 }
        nowPlaying = info
        updateNowPlaying()
        reportExternal()
        return 1
    }

    func updateNowPlaying() {
        guard !nowPlaying.isEmpty else { return }
        var info = nowPlaying
        if let p = player {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime().seconds.isFinite
                ? p.currentTime().seconds : 0
            info[MPNowPlayingInfoPropertyPlaybackRate] = p.rate
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func reportExternal() {
        fire(.externalPlayback, (player?.isExternalPlaybackActive ?? false) ? "1" : "0")
    }

    // An AVPlayer whose layer is on screen is paused by the system when the
    // app goes to the background. Taking the player off the layer keeps the
    // audio going (Apple's "Playing audio from a video asset in the
    // background"). Not while PiP is up: PiP needs the layer.
    @objc func didEnterBackground() {
        guard backgroundEnabled, let l = layer, let p = l.player,
              !(pip?.isPictureInPictureActive ?? false) else { return }
        detached = (l, p)
        l.player = nil
    }

    @objc func willEnterForeground() { restoreDetached() }

    func restoreDetached() {
        if let (l, p) = detached { l.player = p }
        detached = nil
    }

    // AVPictureInPictureControllerDelegate
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        fire(.pipStarted)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        fire(.pipStopped)
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        fire(.pipFailed, "\(error)")
    }
}

@_cdecl("FNMConfigure")
public func FNMConfigure() -> Int32 { MediaSession.shared.configure() }

@_cdecl("FNMAttach")
public func FNMAttach(_ viewPtr: Int64, _ title: UnsafePointer<CChar>,
                      _ artist: UnsafePointer<CChar>, _ durationMs: Int64) -> Int32 {
    MediaSession.shared.attach(view: view(fromPointer: viewPtr),
                               title: String(cString: title),
                               artist: String(cString: artist),
                               durationMs: durationMs)
}

@_cdecl("FNMUpdateNowPlaying")
public func FNMUpdateNowPlaying() { MediaSession.shared.updateNowPlaying() }

@_cdecl("FNMSetBackgroundPlayback")
public func FNMSetBackgroundPlayback(_ on: Int32) { MediaSession.shared.backgroundEnabled = on != 0 }

/// 1 possible, 0 not yet (the layer is not ready), -1 unsupported device.
@_cdecl("FNMPipState")
public func FNMPipState() -> Int32 {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return -1 }
    guard let c = MediaSession.shared.pip else { return 0 }
    if c.isPictureInPictureActive { return 2 }
    return c.isPictureInPicturePossible ? 1 : 0
}

@_cdecl("FNMStartPip")
public func FNMStartPip() -> Int32 {
    guard let c = MediaSession.shared.pip, c.isPictureInPicturePossible else { return 0 }
    c.startPictureInPicture()
    return 1
}

@_cdecl("FNMStopPip")
public func FNMStopPip() { MediaSession.shared.pip?.stopPictureInPicture() }

@_cdecl("FNMIsExternalPlaybackActive")
public func FNMIsExternalPlaybackActive() -> Int32 {
    (MediaSession.shared.player?.isExternalPlaybackActive ?? false) ? 1 : 0
}

// MARK: - AirPlay without a picker per page

// AVRoutePickerView is expensive to create: every instance parses a CAML
// package for its icon (about 100ms of main thread each on an iPhone 16 Pro
// Max, measured). One per feed page cost half a second at launch and more on
// every swipe. So there is one, created on first use, kept in the window at
// near-zero alpha, and a plain glass button taps its button for it.
private var sharedPicker: AVRoutePickerView?

@_cdecl("FNMShowRoutePicker")
public func FNMShowRoutePicker() -> Int32 {
    let picker: AVRoutePickerView
    if let p = sharedPicker, p.window != nil {
        picker = p
    } else {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return 0 }
        let p = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        p.prioritizesVideoDevices = true
        p.alpha = 0.011   // present in the hierarchy, invisible
        p.isUserInteractionEnabled = false
        window.addSubview(p)
        sharedPicker = p
        picker = p
    }
    guard let button = allViews(picker).compactMap({ $0 as? UIButton }).first else {
        log("route picker has no button")
        return 0
    }
    button.sendActions(for: .touchUpInside)
    return 1
}

// MARK: - Pull to refresh

// DartNative has no pull-to-refresh (no RefreshIndicator, no onRefresh on
// FastList or PageView), so this attaches the system's own UIRefreshControl
// to the scroll view PageView is built on. That view is found by shape: the
// visible scroll view that pages vertically.

private final class RefreshTarget: NSObject {
    static let shared = RefreshTarget()
    @objc func pulled() { fire(.refresh) }
}

private func allViews(_ root: UIView) -> [UIView] {
    [root] + root.subviews.flatMap(allViews)
}

private func verticalPager() -> UIScrollView? {
    let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
    let candidates = windows.flatMap(allViews).compactMap { $0 as? UIScrollView }.filter {
        $0.isPagingEnabled && $0.window != nil && !$0.isHidden
            && $0.bounds.height > 200
            && $0.contentSize.height > $0.bounds.height
            && $0.contentSize.width <= $0.bounds.width + 1
    }
    // The visible one: largest on screen.
    return candidates.max { $0.bounds.height * $0.bounds.width < $1.bounds.height * $1.bounds.width }
}

/// 1 installed (or already there), 0 no pager found yet (retry after a frame).
@_cdecl("FNMInstallRefresh")
public func FNMInstallRefresh(_ argb: UInt32) -> Int32 {
    guard let sv = verticalPager() else { return 0 }
    if sv.refreshControl != nil { return 1 }
    let rc = UIRefreshControl()
    rc.tintColor = UIColor(red: CGFloat((argb >> 16) & 0xFF) / 255,
                           green: CGFloat((argb >> 8) & 0xFF) / 255,
                           blue: CGFloat(argb & 0xFF) / 255,
                           alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    rc.addTarget(RefreshTarget.shared, action: #selector(RefreshTarget.pulled), for: .valueChanged)
    sv.refreshControl = rc
    sv.alwaysBounceVertical = true
    log("refresh control on \(type(of: sv)) \(sv.bounds.size) content=\(sv.contentSize)")
    return 1
}

/// Ends the refresh on whichever pager is showing one.
@_cdecl("FNMEndRefresh")
public func FNMEndRefresh() {
    verticalPager()?.refreshControl?.endRefreshing()
}

/// Starts the spinner programmatically (the Home tab re-tap).
@_cdecl("FNMBeginRefresh")
public func FNMBeginRefresh() -> Int32 {
    guard let sv = verticalPager(), let rc = sv.refreshControl else { return 0 }
    rc.beginRefreshing()
    return 1
}

// MARK: - AirPlay route picker view (plugin_development.md §3a)

private let ROUTE_PICKER_KEY = "com.saileshbro.feed_native_media/route_picker"
private let TAG_TINT: Int32 = 1

private let ROUTE_PICKER_TYPE: Int32 = {
    typealias ClaimFn = @convention(c) (UnsafePointer<CChar>) -> Int32
    guard let s = dlsym(dlopen(nil, RTLD_NOLOAD), "DNViewTypeClaim") else { return -1 }
    return ROUTE_PICKER_KEY.withCString { unsafeBitCast(s, to: ClaimFn.self)($0) }
}()

/// Pins the picker to whatever frame Yoga gives the container.
private final class RoutePickerContainer: UIView {
    let picker: AVRoutePickerView = {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.tintColor = .white
        v.activeTintColor = .white
        v.backgroundColor = .clear
        return v
    }()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(picker)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
    }
}

private let createView: @convention(c) (Int32) -> Int64 = { typeIndex in
    guard typeIndex == ROUTE_PICKER_TYPE else { return 0 }
    return Int64(Int(bitPattern: Unmanaged.passRetained(RoutePickerContainer()).toOpaque()))
}

private let handleMutation: @convention(c) (Int64, Int32, UnsafePointer<UInt8>?, Int32) -> Void = {
    viewId, tag, data, len in
    guard let v = viewFor(viewId) as? RoutePickerContainer else { return }
    switch tag {
    case TAG_TINT:
        guard let data, len >= 4 else { return }
        var argb: UInt32 = 0
        memcpy(&argb, data, 4)   // little-endian from Dart
        let c = UIColor(red: CGFloat((argb >> 16) & 0xFF) / 255,
                        green: CGFloat((argb >> 8) & 0xFF) / 255,
                        blue: CGFloat(argb & 0xFF) / 255,
                        alpha: CGFloat((argb >> 24) & 0xFF) / 255)
        v.picker.tintColor = c
        v.picker.activeTintColor = c
    default:
        log("unknown tag \(tag)")
    }
}

private typealias GetViewFn = @convention(c) (Int64) -> Int64
private let dnGetView: GetViewFn? = {
    guard let s = dlsym(dlopen(nil, RTLD_NOLOAD), "DNViewRegistryGetView") else { return nil }
    return unsafeBitCast(s, to: GetViewFn.self)
}()
private func viewFor(_ id: Int64) -> UIView? {
    guard let fn = dnGetView else { return nil }
    let p = fn(id)
    guard p != 0, let raw = UnsafeRawPointer(bitPattern: Int(p)) else { return nil }
    return Unmanaged<UIView>.fromOpaque(raw).takeUnretainedValue()
}

@_cdecl("FNMRegisterProvider")
public func FNMRegisterProvider() {
    guard let s = dlsym(dlopen(nil, RTLD_NOLOAD), "DNRegisterPluginProvider") else {
        log("DNRegisterPluginProvider not found; is dartnative_ios linked?")
        return
    }
    typealias RegFn = @convention(c) (Int64, Int64) -> Void
    unsafeBitCast(s, to: RegFn.self)(
        unsafeBitCast(createView as @convention(c) (Int32) -> Int64, to: Int64.self),
        unsafeBitCast(handleMutation as @convention(c)
            (Int64, Int32, UnsafePointer<UInt8>?, Int32) -> Void, to: Int64.self)
    )
}
