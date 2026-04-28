import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:audiopc_interface/audiopc_interface.dart';
import 'package:web/web.dart' as web;

export 'package:audiopc_interface/audiopc_interface.dart';

/// AudiopcWeb is the main class that implements the audio player functionality using the Web Audio API.
class AudiopcWeb with PlayerStateMixin implements AudiopcInterface {
  late final web.AudioContext _audioContext;
  late final web.GainNode _gainNode;
  late final web.AnalyserNode _analyser;
  web.AudioBuffer? _decodedBuffer;
  web.AudioBufferSourceNode? _currentSource;
  bool _isPlaying = false;
  bool _sourceStopRequested = false;

  double _playbackOffsetSec = 0.0;
  double _playbackStartedAtCtxSec = 0.0;
  double _durationSec = 0.0;

  /// Retrieves information about the audio backend, including the default output sample rate,
  /// number of channels, and available output devices.
  @override
  AudioBackendInfo getAudioBackendInfo() {
    final context = web.AudioContext();
    final sampleRate = context.sampleRate.toInt();
    context.close();
    return AudioBackendInfo(
      defaultOutputSampleRate: sampleRate,
      defaultOutputChannels: 2,
      outputDeviceCount: 1,
    );
  }

  late final Timer _positionTimer;

  /// Creates a player and starts a periodic position publisher.
  AudiopcWeb() {
    _audioContext = web.AudioContext();
    _gainNode = _audioContext.createGain();
    _analyser = _audioContext.createAnalyser();
    _analyser.fftSize = 2048;

    _gainNode.connect(_analyser);
    _analyser.connect(_audioContext.destination);

    _positionTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isPlaying && _durationSec > 0 && _positionSeconds >= _durationSec) {
        _isPlaying = false;
        _playbackOffsetSec = _durationSec;
        _disconnectCurrentSource();
        setState(PlayerState.idle);
      }
      positionController.add(positionMillis);
    });
  }

  void _disconnectCurrentSource() {
    if (_currentSource == null) {
      return;
    }

    try {
      _currentSource!.disconnect();
    } catch (_) {
      // No-op for already-disconnected node.
    }
    _currentSource = null;
  }

  void _stopCurrentSource() {
    if (_currentSource == null) {
      return;
    }

    _sourceStopRequested = true;
    try {
      _currentSource!.stop();
    } catch (_) {
      // No-op for already-stopped node.
    }
    _disconnectCurrentSource();
  }

  double get _positionSeconds {
    if (_isPlaying) {
      final elapsed = _audioContext.currentTime - _playbackStartedAtCtxSec;
      return (_playbackOffsetSec + elapsed).clamp(0.0, _durationSec);
    }
    return _playbackOffsetSec.clamp(0.0, _durationSec);
  }

  void _startSourceAt(double offsetSec) {
    if (_decodedBuffer == null) {
      return;
    }

    _stopCurrentSource();

    final source = _audioContext.createBufferSource();
    source.buffer = _decodedBuffer;
    source.connect(_gainNode);
    source.onended = ((web.Event _) {
      if (_sourceStopRequested) {
        _sourceStopRequested = false;
        return;
      }
      _isPlaying = false;
      _playbackOffsetSec = _durationSec;
      _disconnectCurrentSource();
      setState(PlayerState.idle);
    }).toJS;

    source.start(0, offsetSec);
    _currentSource = source;
    _playbackOffsetSec = offsetSec;
    _playbackStartedAtCtxSec = _audioContext.currentTime;
    _isPlaying = true;
  }

  /// Sets a local file path source.
  ///
  /// On web this is treated as a URL-like resource and fetched by the browser.
  @override
  bool setFileSource(String path) {
    unawaited(_fetchAndDecodeAudio(path));
    return true;
  }

  /// Sets a direct URL source.
  @override
  bool setUrlSource(String url) {
    unawaited(_fetchAndDecodeAudio(url));
    return true;
  }

  /// Sets a byte-array source.
  ///
  /// This backend currently does not decode in-memory buffers directly.
  @override
  bool setMemorySource(List<int> data) {
    // Web backend currently expects URL/path-based sources.
    return false;
  }

  Future<void> _fetchAndDecodeAudio(String source) async {
    try {
      final request = web.Request(source.toJS);
      final response = await web.window.fetch(request).toDart;
      if (!response.ok) {
        setState(PlayerState.stopped);
        return;
      }

      final arrayBuffer = await response.arrayBuffer().toDart;
      final decoded = await _audioContext.decodeAudioData(arrayBuffer).toDart;

      _decodedBuffer = decoded;
      _durationSec = decoded.duration;
      _playbackOffsetSec = 0.0;
      _isPlaying = false;
      _stopCurrentSource();
      setState(PlayerState.idle);
    } catch (e) {
      setState(PlayerState.stopped);
    }
  }

  /// Starts or resumes playback.
  @override
  bool play() {
    if (_decodedBuffer == null) {
      return false;
    }

    if (_audioContext.state == 'suspended') {
      unawaited(_audioContext.resume().toDart);
    }

    if (_isPlaying) {
      return true;
    }

    _startSourceAt(_playbackOffsetSec);
    setState(PlayerState.playing);
    return true;
  }

  /// Pauses playback while preserving the current offset.
  @override
  bool pause() {
    if (!_isPlaying) {
      return true;
    }

    _playbackOffsetSec = _positionSeconds;
    _isPlaying = false;
    _stopCurrentSource();
    unawaited(_audioContext.suspend().toDart);
    setState(PlayerState.paused);
    return true;
  }

  /// Stops playback and rewinds to the beginning.
  @override
  bool stop() {
    _isPlaying = false;
    _playbackOffsetSec = 0.0;
    _stopCurrentSource();
    setState(PlayerState.idle);
    return true;
  }

  /// Sets output gain where 1.0 is the nominal level.
  @override
  bool setVolume(double value) {
    _gainNode.gain.value = value.clamp(0.0, 4.0);
    return true;
  }

  /// Compatibility no-op on web for low-pass control.
  @override
  bool setLowPassHz(double hz) {
    // Placeholder on web backend for API compatibility.
    return true;
  }

  /// Number of buffered samples, unavailable on this backend.
  @override
  int get bufferedSamples => 0; // Web Audio doesn't expose this

  /// Current playback position in milliseconds.
  @override
  int get positionMillis => (_positionSeconds * 1000).toInt();

  /// Total decoded media duration in milliseconds.
  @override
  int get durationMillis => (_durationSec * 1000).toInt();

  /// Number of FFT bins available from the analyser.
  @override
  int get visualizerAvailableSamples => _analyser.frequencyBinCount;

  /// Sample rate used by the active audio context.
  @override
  int get visualizerSampleRate => _audioContext.sampleRate.toInt();

  /// Channel count represented by analyser output.
  @override
  int get visualizerChannels => 1; // Analyser output

  /// Returns normalized analyser data suited for waveform-style rendering.
  @override
  List<double> getVisualizerSamples(int maxSamples) {
    if (maxSamples <= 0) {
      return const [];
    }

    final data = Uint8List(_analyser.frequencyBinCount);
    _analyser.getByteFrequencyData(data.toJS);
    final count = maxSamples.clamp(0, data.length.toInt());

    final out = <double>[];
    for (var i = 0; i < count; i++) {
      out.add(data[i].toDouble() / 255.0);
    }
    return out;
  }

  /// Returns normalized spectrum bars sampled from analyser data.
  @override
  List<double> getVisualizerSpectrum(int barCount) {
    if (barCount <= 0) {
      return const [];
    }

    final data = Uint8List(_analyser.frequencyBinCount);
    _analyser.getByteFrequencyData(data.toJS);

    final result = <double>[];
    final step = data.length.toInt() / barCount;
    for (var i = 0; i < barCount; i++) {
      final idx = (i * step).toInt();
      if (idx < data.length.toInt()) {
        result.add(data[idx].toDouble() / 255.0);
      } else {
        result.add(0.0);
      }
    }
    return result;
  }

  void playSource(String uri) {
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      setUrlSource(uri);
    } else {
      setFileSource(uri);
    }
  }

  void setPlaybackRate(double rate) {
    if (_currentSource != null) {
      _currentSource!.playbackRate.value = rate;
    }
  }

  /// Seeks to a position in milliseconds.
  @override
  void seek(int positionMillis) {
    if (_decodedBuffer == null) {
      return;
    }

    final targetSec = (positionMillis / 1000.0).clamp(0.0, _durationSec);
    final wasPlaying = _isPlaying;

    _playbackOffsetSec = targetSec;
    if (wasPlaying) {
      _startSourceAt(targetSec);
      setState(PlayerState.playing);
    }
  }

  /// Releases browser audio nodes, timers, and stream controllers.
  @override
  void dispose() {
    _isPlaying = false;
    _stopCurrentSource();
    _positionTimer.cancel();
    positionController.close();
    playerStateController.close();
    unawaited(_audioContext.close().toDart);
  }

  @override
  MetaData getMetadata(String url) {
    // TODO: implement getThumbnail
    throw UnimplementedError();
  }

  @override
  Uint8List? getThumbnail(String url, {int maxSize = 20 * 1024 * 1024}) {
    throw UnimplementedError();
  }

  @override
  Stream<int> get positionStream => positionController.stream;

  void setPeakFilter(double cutoffHz, double q, double gainDB) {

  }

  void setLowShelfFilter(double cutoffHz, double q, double gainDB) {

  }

  void setHighShelfFilter(double cutoffHz, double q, double gainDB) {

  }

  void setBandPassFilter(double cutoffHz, double q) {

  }

  void setNotchFilter(double cutoffHz, double q) {

  }

  void clearFilters() {}
}
