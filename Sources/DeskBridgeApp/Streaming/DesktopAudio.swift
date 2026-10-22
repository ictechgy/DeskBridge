// SPDX-License-Identifier: GPL-3.0-only
import AVFAudio
import AudioToolbox
import Foundation
import GlimmerEngine
import Synchronization
import DeskBridgeCore

/// AVAudioEngine pulls the engine's preallocated PCM storage; no packet work occurs on the render thread.
final class DesktopAudio: Sendable {
    private let listener = DesktopNotificationListener()
    func platform() -> AudioPlatform {
        AudioPlatform(makeOutput: { format in try DesktopAudioGraph(format: format).output() },
            sampleRoute: { AudioRoute(label: "System audio output", uid: nil) },
            installRouteListener: { [weak self] queue, _, changed in
                self?.listener.install(center: .default, name: .AVAudioEngineConfigurationChange,
                                       queue: queue, changed: changed)
            }, removeRouteListener: { [weak self] _ in self?.listener.remove() },
            installDeviceListeners: { _, _ in }, removeDeviceListeners: {},
            captureVolume: { { AudioOutputVolume(volume: nil, muted: nil, routeChanged: false) } },
            environment: { AudioEnvironment(host: "paired PC", link: "private network", jitterMs: 0) })
    }
}

private final class DesktopAudioRenderState: Sendable {
    let status = Atomic<Int32>(0)
}
private final class DesktopAudioGraph {
    let engine = AVAudioEngine()
    let speed = AVAudioUnitVarispeed()
    let storage: AudioRenderStorage
    let source: AVAudioSourceNode
    let format: AVAudioFormat
    let renderError: DesktopAudioRenderState
    init(format: AVAudioFormat) throws {
        self.format = format
        let state = DesktopAudioRenderState()
        renderError = state
        let storage = AudioRenderStorage(channels: Int(format.channelCount))
        self.storage = storage
        let callback = storage.renderCallback
        guard let render = callback.inputProc, let context = callback.inputProcRefCon else {
            throw AudioOutput.Failure(status: kAudio_ParamError)
        }
        source = AVAudioSourceNode(format: format) { silence, timestamp, count, buffers in
            var actions: AudioUnitRenderActionFlags = []
            let result = render(context, &actions, timestamp, 0, count, buffers)
            if result != noErr { state.status.store(result, ordering: .relaxed) }
            silence.pointee = ObjCBool(actions.contains(.unitRenderAction_OutputIsSilence))
            return result
        }
        engine.attach(source)
        engine.attach(speed)
        engine.connect(source, to: speed, format: format)
        engine.connect(speed, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }
    func output() -> AudioOutput {
        AudioOutput(storage: storage, sampleRate: format.sampleRate, channels: format.channelCount, latencyMs: 0,
            start: { [self] in
                renderError.status.store(0, ordering: .relaxed)
                do { try engine.start(); return noErr }
                catch { renderError.status.store(-1, ordering: .relaxed); return -1 }
            }, isRunning: { [self] in engine.isRunning },
            setRate: { [self] rate in speed.rate = rate; return noErr },
            lastRenderError: { [self] in renderError.status.load(ordering: .relaxed) })
    }
    deinit {
        engine.stop()
        engine.disconnectNodeOutput(source)
        engine.detach(source)
        engine.detach(speed)
        storage.dispose(using: { true })
    }
}
