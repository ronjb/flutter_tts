import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'interop_types.dart';

enum TtsState { playing, stopped, paused, continued }

class FlutterTtsPlugin {
  static const String platformChannel = "flutter_tts";
  static late MethodChannel channel;
  bool awaitSpeakCompletion = false;

  TtsState ttsState = TtsState.stopped;

  Completer<dynamic>? _speechCompleter;

  bool get isPlaying => ttsState == TtsState.playing;

  bool get isStopped => ttsState == TtsState.stopped;

  bool get isPaused => ttsState == TtsState.paused;

  bool get isContinued => ttsState == TtsState.continued;

  static void registerWith(Registrar registrar) {
    channel =
        MethodChannel(platformChannel, const StandardMethodCodec(), registrar);
    final instance = FlutterTtsPlugin();
    channel.setMethodCallHandler(instance.handleMethodCall);
  }

  /// Identifies the utterance in flight. Each set of handlers captures the id
  /// its utterance was created with and ignores everything else, so the `end`
  /// that `cancel` fires on an interrupted utterance is not reported as the
  /// one replacing it having finished.
  ///
  /// An int rather than comparing the utterance objects: these are extension
  /// types over `JSObject`, and `identical` on those is not dependable across
  /// compilers.
  int _speechId = 0;

  /// Utterance settings, kept here rather than on a long-lived utterance
  /// because every [_speak] builds its own.
  SpeechSynthesisVoice? _voice;
  String? _language;
  double? _rate;
  double? _volume;
  double? _pitch;

  List<SpeechSynthesisVoice> voices = [];
  List<String> languages = [];
  Timer? t;
  bool supported = false;

  FlutterTtsPlugin() {
    try {
      // Discarded — this only proves the browser has the API.
      SpeechSynthesisUtterance();
      supported = true;
    } catch (e) {
      print('Initialization of TTS failed. Functions are disabled. Error: $e');
    }
  }

  void _listeners(SpeechSynthesisUtterance utterance, int id) {
    utterance.onStart = (JSAny e) {
      if (id != _speechId) return;
      ttsState = TtsState.playing;
      channel.invokeMethod("speak.onStart", null);
      var bLocal = (utterance.voice?.isLocalService ?? false);
      if (!bLocal) {
        // Chrome cuts a remote voice off after roughly 15 seconds unless the
        // queue is nudged. Keep nudging until this utterance is done — the
        // nudge itself moves the state to `continued`, so testing for
        // `playing` here would stop after a single pass.
        t?.cancel();
        t = Timer.periodic(Duration(seconds: 14), (t) {
          if (id == _speechId && ttsState != TtsState.stopped) {
            synth.pause();
            synth.resume();
          } else {
            t.cancel();
          }
        });
      }
    }.toJS;

    utterance.onEnd = (JSAny e) {
      if (id != _speechId) return;
      _finish();
      channel.invokeMethod("speak.onComplete", null);
    }.toJS;

    utterance.onPause = (JSAny e) {
      if (id != _speechId) return;
      ttsState = TtsState.paused;
      channel.invokeMethod("speak.onPause", null);
    }.toJS;

    utterance.onResume = (JSAny e) {
      if (id != _speechId) return;
      ttsState = TtsState.continued;
      channel.invokeMethod("speak.onContinue", null);
    }.toJS;

    utterance.onError = (JSObject event) {
      if (id != _speechId) return;
      // Releases anyone awaiting completion — an error ends this utterance
      // just as surely as `end` does, and leaving the completer hanging
      // strands the caller forever.
      _finish();
      print(event); // Log the entire event object to get more details
      channel.invokeMethod("speak.onError", event["error"]);
    }.toJS;

    utterance.onBoundary = (JSObject event) {
      if (id != _speechId) return;
      int charIndex = event['charIndex'] as int;
      String name = event['name'] as String;
      if (name == 'sentence') return;
      String text = utterance['text'] as String;
      int endIndex = charIndex;
      while (endIndex < text.length &&
          !RegExp(r'[\s,.!?]').hasMatch(text[endIndex])) {
        endIndex++;
      }
      String word = text.substring(charIndex, endIndex);
      Map<String, dynamic> progressArgs = {
        'text': text,
        'start': charIndex,
        'end': endIndex,
        'word': word
      };
      channel.invokeMethod("speak.onProgress", progressArgs);
    }.toJS;
  }

  Future<dynamic> handleMethodCall(MethodCall call) async {
    if (!supported) return;
    switch (call.method) {
      case 'speak':
        final text = call.arguments as String?;
        if (text == null || text.isEmpty) return null;
        _speak(text);
        if (awaitSpeakCompletion) {
          return _speechCompleter?.future;
        }
        break;
      case 'awaitSpeakCompletion':
        awaitSpeakCompletion = (call.arguments as bool?) ?? false;
        return 1;
      case 'stop':
        _stop();
        return 1;
      case 'pause':
        _pause();
        return 1;
      case 'setLanguage':
        final language = call.arguments as String;
        _setLanguage(language);
        return 1;
      case 'getLanguages':
        return _getLanguages();
      case 'getVoices':
        return getVoices();
      case 'setVoice':
        final tmpVoiceMap =
            Map<String, String>.from(call.arguments as LinkedHashMap);
        return _setVoice(tmpVoiceMap);
      case 'setSpeechRate':
        final rate = call.arguments as double;
        _setRate(rate);
        return 1;
      case 'setVolume':
        final volume = call.arguments as double;
        _setVolume(volume);
        return 1;
      case 'setPitch':
        final pitch = call.arguments as double;
        _setPitch(pitch);
        return 1;
      case 'isLanguageAvailable':
        final lang = call.arguments as String;
        return _isLanguageAvailable(lang);
      default:
        throw PlatformException(
            code: 'Unimplemented',
            details: "The flutter_tts plugin for web doesn't implement "
                "the method '${call.method}'");
    }
  }

  void _speak(String text) {
    // Clear the queue and speak unconditionally, rather than gating on
    // `ttsState`. That state only leaves `playing` when the browser fires
    // `end` or `error`, and a remote voice that stalls fires neither — which
    // used to mute every later utterance for the life of the page, with
    // nothing able to reset it. Cancelling fires the `end` that clears it.
    //
    // `resume` as well as `cancel` because Chrome keeps `paused` set through
    // a `cancel`, and the keep-alive above pauses the queue every 14 seconds.
    _finish();
    synth.cancel();
    synth.resume();

    final id = _speechId;
    final utterance = SpeechSynthesisUtterance();
    utterance.text = text;
    if (_voice != null) utterance.voice = _voice;
    if (_language != null) utterance.lang = _language!;
    if (_rate != null) utterance.rate = _rate!;
    if (_volume != null) utterance.volume = _volume!;
    if (_pitch != null) utterance.pitch = _pitch!;
    _listeners(utterance, id);

    if (awaitSpeakCompletion) {
      _speechCompleter = Completer<dynamic>();
    }
    synth.speak(utterance);
  }

  void _stop() {
    _finish();
    // Unconditional as well: `cancel` on an idle queue does nothing, and the
    // `resume` clears a `paused` flag that `cancel` alone leaves set.
    synth.cancel();
    synth.resume();
  }

  /// Ends whatever is in flight — orphans its events, stops the keep-alive,
  /// and releases anyone awaiting completion.
  void _finish() {
    _speechId++;
    t?.cancel();
    t = null;
    ttsState = TtsState.stopped;
    final completer = _speechCompleter;
    _speechCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _pause() {
    if (ttsState == TtsState.playing || ttsState == TtsState.continued) {
      synth.pause();
    }
  }

  void _setRate(double rate) => _rate = rate;
  void _setVolume(double volume) => _volume = volume;
  void _setPitch(double pitch) => _pitch = pitch;
  void _setLanguage(String language) {
    var targetList = synth.getVoices().toDart.where((e) {
      return e.lang.toLowerCase().startsWith(language.toLowerCase());
    });
    if (targetList.isNotEmpty) {
      _voice = targetList.first;
      _language = targetList.first.lang;
    }
  }

  void _setVoice(Map<String?, String?> voice) {
    var tmpVoices = synth.getVoices().toDart;
    var targetList = tmpVoices.where((e) {
      return voice["name"] == e.name && voice["locale"] == e.lang;
    });
    if (targetList.isNotEmpty) {
      _voice = targetList.first;
    }
  }

  bool _isLanguageAvailable(String? language) {
    if (voices.isEmpty) _setVoices();
    if (languages.isEmpty) _setLanguages();
    for (var lang in languages) {
      if (!language!.contains('-')) {
        lang = lang.split('-').first;
      }
      if (lang.toLowerCase() == language.toLowerCase()) return true;
    }
    return false;
  }

  List<String?>? _getLanguages() {
    if (voices.isEmpty) _setVoices();
    if (languages.isEmpty) _setLanguages();
    return languages;
  }

  void _setVoices() {
    voices = synth.getVoices().toDart;
  }

  Future<List<Map<String, String>>> getVoices() async {
    var tmpVoices = synth.getVoices().toDart;
    return tmpVoices
        .map((voice) => {"name": voice.name, "locale": voice.lang})
        .toList();
  }

  void _setLanguages() {
    var langs = <String>{};
    for (var v in voices) {
      langs.add(v.lang);
    }

    languages = langs.toList();
  }
}
