import 'dart:async';

import 'package:downloader/features/downloads/data/android_engine.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fixtures.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('downloader/android_engine');
  const events = MethodChannel('downloader/android_engine/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppStore store;
  late AndroidEngine engine;
  late List<MethodCall> calls;
  late List<MethodCall> eventCalls;
  late FutureOr<Object?> Function(MethodCall) respond;
  final ack = ReceiptAck(key: f.key, receiptVersion: 1);
  final input = EngineTask(
    key: f.key,
    url: 'https://example.com/file',
    requestedFileName: '文件.bin',
    directory: DirectoryLocation(
      platform: DownloadPlatform.android,
      kind: DirectoryKind.systemDownloads,
      subdirectory: 'Downloader',
      displayName: '下载',
    ),
    stagingLocation: '/private/staging',
  );
  Map<String, Object?> snapshot({List<EngineReceipt> receipts = const []}) =>
      EngineSnapshot(
        ownerSessionId: 'session',
        sequence: 0,
        receipts: receipts,
      ).toJson();
  Matcher failure(FailureCode code, [String? reason]) =>
      isA<AndroidEngineException>()
          .having((e) => e.failure.code, 'code', code)
          .having((e) => e.failure.details?['reason'], 'reason', reason);
  Future<void> send(Object? value) async {
    await messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  EngineEvent event(int sequence, {String session = 'session'}) => EngineEvent(
    ownerSessionId: session,
    sequence: sequence,
    key: f.key,
    downloadedBytes: 0x100000001,
    sampleMonotonicMs: sequence,
  );
  void commit({EngineReceipt? receipt, ReceiptAck? committedAck}) {
    store.transaction((tx) {
      tx.saveTask(f.task());
      expect(
        tx.commitReceipt(
          f.task(engineReceipt: receipt ?? f.receipt()),
          committedAck ?? ack,
        ),
        isTrue,
      );
    });
  }

  for (final code in [
    FailureCode.permissionDenied,
    FailureCode.backgroundRestricted,
    FailureCode.cleanupFailure,
    FailureCode.fileWriteFailure,
    FailureCode.httpFailure,
    FailureCode.networkUnavailable,
    FailureCode.timeout,
  ]) {
    test(
      'native service ${code.name} is classified without leaking diagnostics',
      () async {
        respond = (_) => throw PlatformException(
          code: code.name,
          message: '/private/material-secret',
          details: {'reason': 'materialReleaseUnavailable', 'path': '/secret'},
        );
        await expectLater(
          engine.enqueue(f.command, input),
          throwsA(failure(code, 'materialReleaseUnavailable')),
        );
        expect(store.readTasks(), isEmpty);
      },
    );
  }

  test(
    'pending terminal save is inspectable as persistence failure and explicit retry keeps identity',
    () async {
      respond = (call) {
        if (call.method == 'inspect') {
          throw PlatformException(
            code: 'persistenceFailure',
            details: {'reason': 'terminalSavePending', 'path': '/secret'},
          );
        }
        return null;
      };
      await expectLater(
        engine.inspect(),
        throwsA(failure(FailureCode.persistenceFailure, 'terminalSavePending')),
      );
      respond = (_) => null;
      await engine.enqueue(f.command, input);
      final request = calls.last.arguments as Map;
      expect(request['commandId'], f.command.commandId);
      expect(request['ownerSessionId'], f.command.ownerSessionId);
      expect(store.readTasks(), isEmpty);
    },
  );

  setUp(() async {
    store = AppStore(sqlite3.openInMemory());
    calls = [];
    eventCalls = [];
    respond = (call) => call.method == 'inspect' ? snapshot() : null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return respond(call);
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      eventCalls.add(call);
      return null;
    });
    engine = await AndroidEngine.open(store: store, isAndroid: true);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() async {
    await engine.close();
    store.close();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'open/listen/close/reconnect never transfer; listen has version',
    () async {
      expect(calls, isEmpty);
      expect(eventCalls.single.method, 'listen');
      expect(eventCalls.single.arguments, {'protocolVersion': 1});
      await engine.close();
      engine = await AndroidEngine.open(store: store, isAndroid: true);
      await engine.inspect();
      expect(calls.map((c) => c.method), ['inspect']);
    },
  );
  test('unsupported platform is a stable failure', () async {
    await expectLater(
      AndroidEngine.open(store: store, isAndroid: false),
      throwsA(failure(FailureCode.protocolMismatch)),
    );
  });
  test('empty inspect retains session and explicit version request', () async {
    final result = await engine.inspect();
    expect(result.ownerSessionId, 'session');
    expect(result.sequence, 0);
    expect(result.receipts, isEmpty);
    expect(calls.single.arguments, {'protocolVersion': 1});
  });
  for (final bad in <Object?>[
    null,
    {},
    {...snapshot(), 'protocolVersion': 2},
    {...snapshot(), 'protocolVersion': 1.0},
    {...snapshot(), 'sequence': '0'},
    {...snapshot(), 'receipts': null},
    {
      ...snapshot(),
      'receipts': [null],
    },
    {...snapshot(), 'ownerSessionId': ''},
    {...snapshot(), 'sequence': -1},
  ]) {
    test('inspect rejects malformed snapshot $bad', () async {
      respond = (_) => bad;
      await expectLater(
        engine.inspect(),
        throwsA(failure(FailureCode.protocolMismatch)),
      );
    });
  }
  test('initial native persistence failure is not empty', () async {
    respond = (_) => throw PlatformException(
      code: 'persistenceFailure',
      message: '/secret/db',
    );
    await expectLater(
      engine.inspect(),
      throwsA(failure(FailureCode.persistenceFailure)),
    );
  });
  test('unknown native errors and diagnostic paths do not escape', () async {
    respond = (_) => throw PlatformException(
      code: '/secret',
      message: '/private/file',
      details: {'reason': '/secret', 'path': '/private/file'},
    );
    try {
      await engine.inspect();
      fail('must fail');
    } on AndroidEngineException catch (error) {
      expect(error.failure.code, FailureCode.protocolMismatch);
      expect(error.failure.details, isNull);
      expect(error.toString(), isNot(contains('/')));
      expect(error.failure.message, isNot(contains('/')));
    }
  });
  test(
    'enqueue maps full input and command explicitly; duplicate retains ID',
    () async {
      await engine.enqueue(f.command, input);
      await engine.enqueue(f.command, input);
      final expected = {
        'protocolVersion': 1,
        'taskId': 'task',
        'engineId': 'engine',
        'generation': 0,
        'commandId': 'command',
        'ownerSessionId': 'session',
        'expectedReceiptVersion': 0,
        'input': input.toJson(),
      };
      expect(calls.map((c) => c.method), ['enqueue', 'enqueue']);
      expect(calls.map((c) => c.arguments), [expected, expected]);
    },
  );
  test(
    'enqueue mismatched nested key is rejected without native calls',
    () async {
      final wrong = EngineTask(
        key: ExecutionKey(taskId: 'other', engineId: 'engine', generation: 0),
        url: input.url,
        directory: input.directory,
        stagingLocation: input.stagingLocation,
      );
      await expectLater(
        engine.enqueue(f.command, wrong),
        throwsA(failure(FailureCode.stateConflict, 'staleExecution')),
      );
      expect(calls, isEmpty);
    },
  );
  test('old captured session is never rebound or retried', () async {
    respond = (_) => throw PlatformException(
      code: 'stateConflict',
      details: {'reason': 'staleSession'},
    );
    await expectLater(
      engine.resume(f.command),
      throwsA(failure(FailureCode.stateConflict, 'staleSession')),
    );
    expect(calls.single.method, 'resume');
    expect((calls.single.arguments as Map)['ownerSessionId'], 'session');
  });
  test('transferUnavailable propagates for all commands', () async {
    respond = (_) => throw PlatformException(
      code: 'stateConflict',
      details: {'reason': 'transferUnavailable'},
    );
    for (final action in <Future<Object?> Function()>[
      () => engine.enqueue(f.command, input),
      () => engine.resume(f.command),
      () => engine.pause(f.command),
      () => engine.cancel(f.command),
    ]) {
      await expectLater(
        action(),
        throwsA(failure(FailureCode.stateConflict, 'transferUnavailable')),
      );
    }
    expect(calls.map((c) => c.method), [
      'enqueue',
      'resume',
      'pause',
      'cancel',
    ]);
    for (final call in calls) {
      expect((call.arguments as Map)['key'], isNull);
      expect((call.arguments as Map)['commandId'], 'command');
    }
  });
  test('pause/cancel parse actual matching durable receipts', () async {
    respond = (call) => call.method == 'pause'
        ? f.receipt().toJson()
        : {...f.receipt().toJson(), 'state': 'cancelling'};
    expect((await engine.pause(f.command)).toJson(), f.receipt().toJson());
    expect((await engine.cancel(f.command)).state, DownloadStatus.cancelling);
  });
  test('pause refuses null or wrong state as success', () async {
    await expectLater(
      engine.pause(f.command),
      throwsA(failure(FailureCode.protocolMismatch)),
    );
    respond = (_) => {...f.receipt().toJson(), 'state': 'running'};
    await expectLater(
      engine.pause(f.command),
      throwsA(failure(FailureCode.stateConflict, 'receiptPayload')),
    );
  });
  test(
    'events preserve bytes and sequence; reject duplicates, bad type and session',
    () async {
      final received = <EngineEvent>[];
      final errors = <Object>[];
      final sub = engine.events.listen(received.add, onError: errors.add);
      await send(event(1).toJson());
      await send(event(2).toJson());
      await send(event(2).toJson());
      await send({...event(3).toJson(), 'downloadedBytes': '3'});
      await send(event(3, session: 'other').toJson());
      await send(event(3).toJson());
      expect(received.map((e) => e.sequence), [1, 2, 3]);
      expect(received.first.downloadedBytes, 0x100000001);
      expect(received.first.totalBytes, isNull);
      expect(errors, hasLength(3));
      expect(errors.every((e) => e is AndroidEngineException), isTrue);
      expect(calls, isEmpty);
      await sub.cancel();
    },
  );
  test(
    'uncommitted ack and changed release payload never call native',
    () async {
      await expectLater(
        engine.acknowledge(ack),
        throwsA(
          failure(FailureCode.stateConflict, 'uncommittedAcknowledgement'),
        ),
      );
      commit();
      await expectLater(
        engine.acknowledge(
          ReceiptAck(
            key: f.key,
            receiptVersion: 1,
            releaseResumeRefs: ['different'],
          ),
        ),
        throwsA(
          failure(FailureCode.stateConflict, 'uncommittedAcknowledgement'),
        ),
      );
      expect(calls, isEmpty);
    },
  );
  test('completed release uses exact AppStore transaction and refuses path authorization', () async {
    final operation = PublishOperation.fromJson({...f.publication.toJson(), 'phase': 'published', 'targetRef': f.location.locator, 'identity': f.location.identity});
    final receipt = EngineReceipt.fromJson({...f.receipt().toJson(), 'state': 'completed', 'resumeRef': 'complete:opaque', 'publishedLocation': f.location.toJson(), 'publishOperation': operation.toJson()});
    final release = ReceiptAck(key: f.key, receiptVersion: 1, releaseResumeRefs: ['complete:opaque']);
    final task = DownloadTask.fromJson({...f.task().toJson(), 'status': 'completed', 'engineReceipt': receipt.toJson(), 'fileLocation': f.location.toJson(), 'publishOperation': operation.toJson()});
    store.transaction((tx) { tx.saveTask(f.task()); expect(tx.commitReceipt(task, release), isTrue); });
    respond = (call) => call.method == 'inspect' ? snapshot(receipts: [receipt]) : null;
    await expectLater(engine.acknowledge(ReceiptAck(key: f.key, receiptVersion: 1, releaseResumeRefs: [f.location.locator])), throwsA(failure(FailureCode.stateConflict, 'uncommittedAcknowledgement')));
    expect(calls, isEmpty);
    await engine.acknowledge(release);
    expect(calls.map((call) => call.method), ['inspect', 'acknowledge']);
    expect((calls.last.arguments as Map)['releaseResumeRefs'], ['complete:opaque']);
  });

  test(
    'committed receipt matches entire native payload before flat ack',
    () async {
      commit();
      respond = (call) =>
          call.method == 'inspect' ? snapshot(receipts: [f.receipt()]) : null;
      await engine.acknowledge(ack);
      expect(calls.map((c) => c.method), ['inspect', 'acknowledge']);
      expect(calls.last.arguments, {
        'protocolVersion': 1,
        'taskId': 'task',
        'engineId': 'engine',
        'generation': 0,
        'receiptVersion': 1,
        'releaseResumeRefs': [],
      });
      expect(store.readAcknowledgements().single.toJson(), ack.toJson());
    },
  );
  test(
    'same version different full receipt or missing receipt refuses ack',
    () async {
      commit();
      final changed = EngineReceipt.fromJson({
        ...f.receipt().toJson(),
        'resumeRef': 'different',
      });
      respond = (_) => snapshot(receipts: [changed]);
      await expectLater(
        engine.acknowledge(ack),
        throwsA(failure(FailureCode.stateConflict, 'receiptPayload')),
      );
      respond = (_) => snapshot();
      await expectLater(
        engine.acknowledge(ack),
        throwsA(failure(FailureCode.stateConflict, 'receiptPayload')),
      );
      expect(calls.every((c) => c.method == 'inspect'), isTrue);
    },
  );
  test(
    'old ack is not treated as persisted when commitReceipt returns false',
    () async {
      commit(
        receipt: f.receipt(version: 2),
        committedAck: ReceiptAck(key: f.key, receiptVersion: 2),
      );
      expect(
        store.transaction(
          (tx) => tx.commitReceipt(f.task(engineReceipt: f.receipt()), ack),
        ),
        isFalse,
      );
      await expectLater(
        engine.acknowledge(ack),
        throwsA(
          failure(FailureCode.stateConflict, 'uncommittedAcknowledgement'),
        ),
      );
      expect(calls, isEmpty);
    },
  );
  test(
    'persisted old ack with newer business receipt replays actual row',
    () async {
      commit();
      store.transaction(
        (tx) => tx.saveTask(f.task(engineReceipt: f.receipt(version: 2))),
      );
      await engine.acknowledge(ack);
      expect(calls.single.method, 'acknowledge');
      expect(store.readTask('task')!.engineReceipt!.receiptVersion, 2);
    },
  );
  test(
    'removed task retains ack and cannot authorize completed source release',
    () async {
      final release = ReceiptAck(
        key: f.key,
        receiptVersion: 1,
        releaseResumeRefs: ['private-resume-1'],
      );
      store.transaction((tx) {
        tx.saveTask(f.task(engineReceipt: f.receipt()));
        tx.saveAcknowledgement(release);
        tx.deleteTask('task');
      });
      respond = (_) => throw PlatformException(
        code: 'stateConflict',
        details: {'reason': 'materialReleaseUnavailable'},
      );
      await expectLater(
        engine.acknowledge(release),
        throwsA(
          failure(FailureCode.stateConflict, 'uncommittedReceipt'),
        ),
      );
      expect(calls, isEmpty);
      expect(store.readAcknowledgements().single.toJson(), release.toJson());
      expect(store.readTask('task'), isNull);
    },
  );
  test(
    'native ack failure retains committed business receipt and ack',
    () async {
      commit();
      respond = (call) {
        if (call.method == 'inspect') return snapshot(receipts: [f.receipt()]);
        throw PlatformException(code: 'persistenceFailure', message: '/secret');
      };
      await expectLater(
        engine.acknowledge(ack),
        throwsA(failure(FailureCode.persistenceFailure)),
      );
      expect(
        store.readTask('task')!.engineReceipt!.toJson(),
        f.receipt().toJson(),
      );
      expect(store.readAcknowledgements().single.toJson(), ack.toJson());
    },
  );
  test('business store read failure is stable persistence failure', () async {
    store.close();
    await expectLater(
      engine.acknowledge(ack),
      throwsA(failure(FailureCode.persistenceFailure)),
    );
    expect(calls, isEmpty);
  });
  test('ack superseded during native inspect is not forwarded', () async {
    commit();
    final newer = ReceiptAck(key: f.key, receiptVersion: 2);
    respond = (call) {
      store.transaction(
        (tx) => tx.commitReceipt(
          f.task(engineReceipt: f.receipt(version: 2)),
          newer,
        ),
      );
      return snapshot(receipts: [f.receipt()]);
    };
    await expectLater(
      engine.acknowledge(ack),
      throwsA(failure(FailureCode.stateConflict, 'uncommittedAcknowledgement')),
    );
    expect(calls.single.method, 'inspect');
    expect(store.readAcknowledgements().single.toJson(), newer.toJson());
  });
  test(
    'event protocol versions and native errors are stable stream failures',
    () async {
      final errors = <Object>[];
      final sub = engine.events.listen(
        (_) => fail('invalid event delivered'),
        onError: errors.add,
      );
      await send({...event(1).toJson(), 'protocolVersion': 2});
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeErrorEnvelope(
          code: 'unknown',
          message: '/secret',
          details: {'path': '/private'},
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(2));
      expect(errors.every((e) => e is AndroidEngineException), isTrue);
      await sub.cancel();
    },
  );
  test('enqueue refuses another platform without native calls', () async {
    final wrong = EngineTask(
      key: f.key,
      url: input.url,
      directory: f.directory,
      stagingLocation: input.stagingLocation,
    );
    await expectLater(
      engine.enqueue(f.command, wrong),
      throwsA(failure(FailureCode.stateConflict, 'staleExecution')),
    );
    expect(calls, isEmpty);
  });
  test(
    'initial events and errors survive until first business listener',
    () async {
      await send(event(1).toJson());
      await send({...event(2).toJson(), 'sequence': 2.0});
      final received = <EngineEvent>[];
      final errors = <Object>[];
      final sub = engine.events.listen(received.add, onError: errors.add);
      await Future<void>.delayed(Duration.zero);
      expect(received.map((e) => e.sequence), [1]);
      expect(errors.single, failure(FailureCode.protocolMismatch));
      expect(calls, isEmpty);
      await sub.cancel();
    },
  );

  test(
    'explicit inspect authorizes new session and sequence baseline',
    () async {
      final received = <EngineEvent>[];
      final errors = <Object>[];
      final sub = engine.events.listen(received.add, onError: errors.add);
      await send(event(9).toJson());
      await send(event(1, session: 'new').toJson());
      respond = (_) => {...snapshot(), 'ownerSessionId': 'new', 'sequence': 3};
      await engine.inspect();
      await send(event(3, session: 'new').toJson());
      await send(event(4, session: 'new').toJson());
      await send(event(10).toJson());
      expect(received.map((e) => e.sequence), [9, 4]);
      expect(errors, hasLength(3));
      expect(calls.map((c) => c.method), ['inspect']);
      await sub.cancel();
    },
  );

  test('inspect cannot lower a same-session live event sequence', () async {
    final result = Completer<Object?>();
    respond = (_) => result.future;
    final received = <EngineEvent>[];
    final errors = <Object>[];
    final sub = engine.events.listen(received.add, onError: errors.add);
    final inspection = engine.inspect();
    await send(event(8).toJson());
    result.complete({...snapshot(), 'sequence': 4});
    await inspection;
    await send(event(7).toJson());
    await send(event(9).toJson());
    expect(received.map((e) => e.sequence), [8, 9]);
    expect(errors.single, failure(FailureCode.stateConflict, 'eventSequence'));
    await sub.cancel();
  });

  test('late older inspect cannot restore an obsolete session', () async {
    final first = Completer<Object?>();
    var count = 0;
    respond = (_) =>
        ++count == 1 ? first.future : {...snapshot(), 'ownerSessionId': 'new'};
    final received = <EngineEvent>[];
    final sub = engine.events.listen(received.add);
    final old = engine.inspect();
    await Future<void>.delayed(Duration.zero);
    await engine.inspect();
    first.complete(snapshot());
    await old;
    await send(event(1, session: 'new').toJson());
    expect(received.single.ownerSessionId, 'new');
    await sub.cancel();
  });

  test(
    'same ack cannot authorize replaced business receipt during inspect',
    () async {
      commit();
      final changed = EngineReceipt.fromJson({
        ...f.receipt().toJson(),
        'resumeRef': 'replacement',
      });
      respond = (_) {
        store.transaction((tx) {
          tx.deleteTask('task');
          tx.saveTask(f.task(engineReceipt: changed));
        });
        return snapshot(receipts: [f.receipt()]);
      };
      await expectLater(
        engine.acknowledge(ack),
        throwsA(failure(FailureCode.stateConflict, 'receiptPayload')),
      );
      expect(calls.single.method, 'inspect');
      expect(store.readTask('task')!.engineReceipt!.resumeRef, 'replacement');
      expect(store.readAcknowledgements().single.toJson(), ack.toJson());
    },
  );

  for (final mutation in ['delete', 'newer', 'generation']) {
    test(
      'ack safely replays actual row after $mutation during inspect',
      () async {
        commit();
        respond = (call) {
          if (call.method != 'inspect') return null;
          store.transaction((tx) {
            if (mutation == 'delete') {
              tx.deleteTask('task');
            } else if (mutation == 'newer') {
              tx.saveTask(f.task(engineReceipt: f.receipt(version: 2)));
            } else {
              tx.saveTask(
                DownloadTask.fromJson({...f.task().toJson(), 'generation': 1}),
              );
            }
          });
          return snapshot(receipts: [f.receipt()]);
        };
        await engine.acknowledge(ack);
        expect(calls.map((c) => c.method), ['inspect', 'acknowledge']);
        expect(store.readAcknowledgements().single.toJson(), ack.toJson());
      },
    );
  }

  test(
    'pause and cancel reject wrong execution, state, and old version',
    () async {
      final command = EngineCommand(
        commandId: 'stop',
        key: f.key,
        ownerSessionId: 'session',
        expectedReceiptVersion: 2,
      );
      for (final method in ['pause', 'cancel']) {
        for (final change in <Map<String, Object?>>[
          {
            'key': ExecutionKey(
              taskId: 'other',
              engineId: 'engine',
              generation: 0,
            ).toJson(),
            'publishOperation': null,
          },
          {'state': 'running'},
          {'receiptVersion': 1},
        ]) {
          respond = (_) => {
            ...f.receipt(version: 3).toJson(),
            'state': method == 'pause' ? 'paused' : 'cancelling',
            ...change,
          };
          await expectLater(
            method == 'pause' ? engine.pause(command) : engine.cancel(command),
            throwsA(failure(FailureCode.stateConflict, 'receiptPayload')),
          );
        }
      }
    },
  );

  test(
    'void commands accept native null and durable receipt returns',
    () async {
      await engine.enqueue(f.command, input);
      await engine.resume(f.command);
      respond = (_) => f.receipt().toJson();
      await engine.enqueue(f.command, input);
      await engine.resume(f.command);
      expect(calls.map((c) => c.method), [
        'enqueue',
        'resume',
        'enqueue',
        'resume',
      ]);
    },
  );

  test(
    'close during inspect prevents late ack and retains business rows',
    () async {
      commit();
      final pending = Completer<Object?>();
      respond = (_) => pending.future;
      final result = engine.acknowledge(ack);
      final assertion = expectLater(
        result,
        throwsA(failure(FailureCode.stateConflict, 'closed')),
      );
      await Future<void>.delayed(Duration.zero);
      await engine.close();
      pending.complete(snapshot(receipts: [f.receipt()]));
      await assertion;
      expect(calls.single.method, 'inspect');
      expect(store.readAcknowledgements().single.toJson(), ack.toJson());
      await expectLater(
        engine.resume(f.command),
        throwsA(failure(FailureCode.stateConflict, 'closed')),
      );
    },
  );
  test(
    'sequence gaps remain visible for explicit repository synchronization',
    () async {
      final received = <EngineEvent>[];
      final sub = engine.events.listen(received.add);
      await send(event(1).toJson());
      await send(event(7).toJson());
      expect(received.map((e) => e.sequence), [1, 7]);
      expect(calls, isEmpty);
      await sub.cancel();
    },
  );

  test(
    'native stream error before first listener is buffered and sanitized',
    () async {
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeErrorEnvelope(
          code: 'persistenceFailure',
          message: '/secret/native',
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      final errors = <Object>[];
      final sub = engine.events.listen(
        (_) => fail('unexpected event'),
        onError: errors.add,
      );
      await Future<void>.delayed(Duration.zero);
      expect(errors.single, failure(FailureCode.persistenceFailure));
      await sub.cancel();
    },
  );

  test(
    'close drains prior stream error then ignores late native deliveries',
    () async {
      final errors = <Object>[];
      final done = Completer<void>();
      final sub = engine.events.listen(
        (_) => fail('unexpected event'),
        onError: errors.add,
        onDone: done.complete,
      );
      await send({...event(1).toJson(), 'protocolVersion': 2});
      await engine.close();
      await done.future;
      await send(event(2).toJson());
      expect(errors.single, failure(FailureCode.protocolMismatch));
      expect(calls, isEmpty);
      expect(eventCalls.map((c) => c.method), ['listen', 'cancel']);
      await sub.cancel();
    },
  );
}
