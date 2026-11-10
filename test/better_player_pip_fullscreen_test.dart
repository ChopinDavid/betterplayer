import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'better_player_mock_controller.dart';
import 'better_player_test_utils.dart';
import 'mock_global_key.dart';
import 'mock_method_channel.dart';

/// On Android, entering picture-in-picture also enters BetterPlayer's
/// fullscreen so the video fills the PiP window. That fullscreen must not
/// request an orientation, a system UI mode or a wakelock change: the
/// activity is being pinned, and a rotation request landing inside that
/// window-manager transition wedges the system PiP controller (Android 17
/// PiP2 drops to an undefined state and the window can no longer be moved,
/// expanded or closed).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final MockMethodChannel mockMethodChannel = MockMethodChannel();
  const MethodChannel wakelockChannel = MethodChannel('dev.fluttercommunity.plus/wakelock');

  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      mockMethodChannel.channel,
      mockMethodChannel.handle,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      wakelockChannel,
      (_) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(wakelockChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  /// A controller whose video player controller is the real one bound to the
  /// mocked platform channel, so the controller's own video-state listener is
  /// attached and PiP start/stop can be driven through `value`.
  Future<BetterPlayerController> setupPipCapableController() async {
    final controller = BetterPlayerMockController(const BetterPlayerConfiguration());
    await controller.setupDataSource(BetterPlayerDataSource.network(BetterPlayerTestUtils.forBiggerBlazesUrl));
    return controller;
  }

  void simulatePipEnded(BetterPlayerController controller) {
    final videoPlayerController = controller.videoPlayerController!;
    videoPlayerController.value = videoPlayerController.value.copyWith(isPip: true);
    videoPlayerController.value = videoPlayerController.value.copyWith(isPip: false);
  }

  group('BetterPlayerController Android PiP fullscreen', () {
    test('posts pipStart before entering fullscreen', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = await setupPipCapableController();
      bool? fullScreenWhenPipStarted;
      controller.addEventsListener((event) {
        if (event.betterPlayerEventType == BetterPlayerEventType.pipStart) {
          fullScreenWhenPipStarted = controller.isFullScreen;
        }
      });

      await controller.enablePictureInPicture(const MockGlobalKey());

      expect(fullScreenWhenPipStarted, isFalse);
      expect(controller.isFullScreen, isTrue);
    });

    test('marks the fullscreen as entered for PiP', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = await setupPipCapableController();

      await controller.enablePictureInPicture(const MockGlobalKey());

      expect(controller.isFullScreenForPip, isTrue);
    });

    test('on iOS neither enters fullscreen nor marks it as PiP', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final controller = await setupPipCapableController();

      await controller.enablePictureInPicture(const MockGlobalKey());

      expect(controller.isFullScreen, isFalse);
      expect(controller.isFullScreenForPip, isFalse);
    });

    test('exits fullscreen and clears the PiP flag when PiP ends', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = await setupPipCapableController();
      await controller.enablePictureInPicture(const MockGlobalKey());

      simulatePipEnded(controller);

      expect(controller.isFullScreen, isFalse);
      expect(controller.isFullScreenForPip, isFalse);
    });
  });

  group('BetterPlayer widget fullscreen entered for Android PiP', () {
    late List<MethodCall> platformCalls;

    List<String> orientationAndUiModeCalls() => platformCalls
        .map((call) => call.method)
        .where(
          (method) =>
              method == 'SystemChrome.setPreferredOrientations' || method == 'SystemChrome.setEnabledSystemUIMode',
        )
        .toList();

    setUp(() {
      platformCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    Future<BetterPlayerController> pumpPlayer(WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = await setupPipCapableController();
      await tester.pumpWidget(MaterialApp(home: BetterPlayer(controller: controller)));
      await tester.pump();
      platformCalls.clear();
      return controller;
    }

    /// testWidgets verifies foundation debug variables are back to their
    /// defaults before the body returns, so the platform override is reset
    /// here rather than in tearDown.
    Future<void> unmount(WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(Container());
    }

    Future<void> pumpTransition(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    NavigatorState navigatorOf(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator));

    testWidgets('pushes the fullscreen route without orientation or system UI requests', (WidgetTester tester) async {
      final controller = await pumpPlayer(tester);

      await controller.enablePictureInPicture(const MockGlobalKey());
      await pumpTransition(tester);

      expect(navigatorOf(tester).canPop(), isTrue);
      expect(orientationAndUiModeCalls(), isEmpty);

      await unmount(tester);
    });

    testWidgets('a user fullscreen still requests the configured orientations', (WidgetTester tester) async {
      final controller = await pumpPlayer(tester);

      controller.enterFullScreen();
      await pumpTransition(tester);

      expect(navigatorOf(tester).canPop(), isTrue);
      expect(
        orientationAndUiModeCalls(),
        containsAll(['SystemChrome.setPreferredOrientations', 'SystemChrome.setEnabledSystemUIMode']),
      );

      await unmount(tester);
    });

    testWidgets('leaving PiP pops the fullscreen route without restoring orientation '
        'or system UI', (WidgetTester tester) async {
      final controller = await pumpPlayer(tester);
      await controller.enablePictureInPicture(const MockGlobalKey());
      await pumpTransition(tester);
      platformCalls.clear();

      simulatePipEnded(controller);
      await pumpTransition(tester);

      expect(navigatorOf(tester).canPop(), isFalse);
      expect(controller.isFullScreen, isFalse);
      expect(orientationAndUiModeCalls(), isEmpty);

      await unmount(tester);
    });
  });
}
