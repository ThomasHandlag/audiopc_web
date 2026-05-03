import 'dart:async' show Timer;
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:audiopc_interface/audiopc_interface.dart';
import 'package:audiopc_web/src/metadata_extractor.dart';
import 'package:web/web.dart';

import 'helpers.dart';

/// AudiopcWeb is the main class that implements the audio player functionality using the Web Audio API.
class AudiopcWeb with PlayerStateMixin implements AudiopcInterface {
  late final AudioContext _audioContext;
  late final GainNode _gainNode;
  late final AnalyserNode _analyser;
  late final MediaElementAudioSourceNode _track;
  late final AudioBufferSourceNode _bufferSourceNode;
  late final BiquadFilterNode _biquadFilter;
  late final Timer _positionTimer;
  final HTMLAudioElement _audioElement =
      document.createElement('audio') as HTMLAudioElement;

  double _playbackRate = 1.0;

  /// Retrieves information about the audio backend, including the default output sample rate,
  /// number of channels, and available output devices.
  @override
  AudioBackendInfo getAudioBackendInfo() {
    final context = AudioContext();
    final sampleRate = context.sampleRate.toInt();
    context.close();
    return AudioBackendInfo(
      defaultOutputSampleRate: sampleRate,
      defaultOutputChannels: 2,
      outputDeviceCount: 1,
    );
  }

  /// Creates a player and starts a periodic position publisher.
  AudiopcWeb() {
    _audioContext = AudioContext();
    _gainNode = _audioContext.createGain();
    _analyser = _audioContext.createAnalyser();
    _analyser.fftSize = 2048;
    _track = _audioContext.createMediaElementSource(_audioElement);
    _bufferSourceNode = _audioContext.createBufferSource();
    _biquadFilter = _audioContext.createBiquadFilter();

    _audioElement
      ..addEventListener(
        'error',
        (Event event) {
          log(
            'Audio element error: ${_audioElement.error?.message ?? 'Unknown error'}',
          );
          setState(PlayerState.stopped);
        }.toJS,
      )
      ..addEventListener(
        'progress',
        (Event event) {
          if (_audioElement.paused) {
            setState(PlayerState.paused);
            return;
          }
          positionController.add((_audioElement.currentTime * 1000).toInt());
        }.toJS,
      )
      ..addEventListener(
        'ended',
        (Event event) {
          setState(PlayerState.stopped);
        }.toJS,
      );

    _track
        .connect(_gainNode)
        ?.connect(_analyser)
        ?.connect(_biquadFilter)
        ?.connect(_audioContext.destination);

    _positionTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (_audioElement.paused || _audioElement.src.isEmpty) {
        return;
      }
      positionController.add((_audioElement.currentTime * 1000).toInt());
    });
  }

  @override
  bool setFileSource(String path) {
    _audioElement.src = path;
    return true;
  }

  /// Sets a direct URL source.
  @override
  bool setUrlSource(String uri) {
    _audioElement.src = uri;
    return true;
  }

  /// Sets a byte-array source.
  ///
  /// On web this is decoded directly so file picker uploads can play without a fetchable URL.
  @override
  bool setMemorySource(List<int> data) {
    // _audioElement.pause();
    // _audioElement.removeAttribute('src');
    // _audioElement.load();
    _decodeAudioBytes(Uint8List.fromList(data));
    return true;
  }

  Future<void> _decodeAudioBytes(Uint8List bytes) async {
    try {
      final buffer = _audioContext.decodeAudioData(bytes.buffer.toJS);
      final audioBuffer = await buffer.toDart;
      _bufferSourceNode = _audioContext.createBufferSource();
      _bufferSourceNode.buffer = audioBuffer;
      _track
          .connect(_bufferSourceNode)
          ?.connect(_gainNode)
          ?.connect(_analyser)
          ?.connect(_audioContext.destination);
      setState(PlayerState.idle);
    } catch (e) {
      log('Error decoding audio data: $e');
      setState(PlayerState.stopped);
    }
  }

  @override
  bool play() {
    if (_audioElement.src.isEmpty) {
      log('No audio source set. Cannot play.');
      return false;
    }

    if (_audioContext.state == "suspended") {
      _audioContext.resume();
    }

    _audioElement.play();

    return true;
  }

  /// Pauses playback while preserving the current offset.
  @override
  bool pause() {
    _audioElement.pause();
    return true;
  }

  /// Stops playback and rewinds to the beginning.
  @override
  bool stop() {
    _audioElement.pause();
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
  int get positionMillis => (_audioElement.currentTime * 1000).toInt();

  /// Total decoded media duration in milliseconds.
  @override
  int get durationMillis => _audioContext.currentTime.isNaN
      ? 0
      : (_audioElement.duration.isNaN
            ? 0
            : (_audioElement.duration * 1000).toInt());

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
    play();
  }

  /// Seeks to a position in milliseconds.
  @override
  void seek(int positionMillis) {
    if (_audioElement.src.isEmpty) {
      return;
    }

    if (_audioElement.duration.isNaN) {
      return;
    }
    _audioElement.currentTime = positionMillis / 1000.0;
    return;
  }

  @override
  void dispose() {
    _audioContext.close();
    _positionTimer.cancel();
  }

  @override
  Future<MetaData?> getMetadata(String url) async {
    final extractor = MetaDataExtractor();

    final jsonMap = await extractor.getMetadata(url);
    if (jsonMap == null) {
      return null;
    }

    return MetaData.fromJson(jsonMap);
  }

  @override
  Future<Uint8List?> getThumbnail(
    String uri, {
    int maxSize = 20 * 1024 * 1024,
  }) async {
    final extractor = MetaDataExtractor();
    try {
      // 1. Fetch the audio file from the URL using the browser's fetch API
      final responsePromise = window.fetch(uri.toJS);
      final response = await responsePromise.toDart;

      if (!response.ok) {
        log('Failed to fetch audio file: ${response.statusText}');
        return null;
      }

      // 2. Convert response stream to an ArrayBuffer
      final bufferPromise = response.arrayBuffer();
      final jsBuffer = await bufferPromise.toDart;

      // 3. Convert JS ArrayBuffer into Dart's ByteBuffer
      final dartBuffer = jsBuffer.toDart;

      // 4. Extract and return the embedded cover art
      return extractor.extractCoverArt(dartBuffer.asUint8List());
    } catch (e) {
      log('Error extracting thumbnail: $e');
      return null;
    }
  }

  @override
  Stream<int> get positionStream => positionController.stream;

  void _biquad(String type, cutoffHz, double q, double gainDB) {
    try {
      // Set filter type (Web Audio accepts strings like 'lowshelf', 'highshelf', etc.)
      _biquadFilter.type = type;

      // Ensure numeric frequency value
      final freq = cutoffHz is num
          ? cutoffHz.toDouble()
          : double.tryParse(cutoffHz.toString()) ?? 0.0;
      _biquadFilter.frequency.value = freq;
      _biquadFilter.Q.value = q;
      _biquadFilter.gain.value = gainDB;

      // Reconnect the node chain so the biquad filter is in the path
      _track
          .connect(_gainNode)
          ?.connect(_analyser)
          ?.connect(_biquadFilter)
          ?.connect(_audioContext.destination);
    } catch (e) {
      log('Error configuring biquad filter: $e');
    }
  }

  @override
  bool setPeakFilter(double cutoffHz, double q, double gainDB) {
    _biquad('peaking', cutoffHz, q, gainDB);
    return true;
  }

  @override
  bool setLowShelfFilter(double cutoffHz, double q, double gainDB) {
    _biquad('lowshelf', cutoffHz, q, gainDB);
    return true;
  }

  @override
  bool setHighShelfFilter(double cutoffHz, double q, double gainDB) {
    _biquad('highshelf', cutoffHz, q, gainDB);
    return true;
  }

  @override
  bool setNotchFilter(double cutoffHz, double q, double _) {
    _biquad('notch', cutoffHz, q, 0);
    return true;
  }

  void clearFilters() {
    _biquadFilter.disconnect(_audioContext.destination);
  }

  @override
  bool setBandPassHz(double min, double max) {
    _biquad('bandpass', min, max, 0);
    return true;
  }

  @override
  bool setCombFilter(double delayMs, double feedback, double damp) {
    _biquad('comb', delayMs, feedback, damp);
    return true;
  }

  @override
  bool setHighPassHz(double hz) {
    _biquad('highpass', hz, 1.0, 0);
    return true;
  }

  @override
  bool setRate(double rate) {
    _playbackRate = rate.clamp(0.5, 2.0);
    _audioElement.playbackRate = _playbackRate;

    return true;
  }

  @override
  bool setReverb(
    double roomSize,
    double damping,
    double wetLevel,
    double dryLevel,
  ) {
    return true;
  }
}
