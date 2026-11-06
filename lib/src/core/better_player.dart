// Navigator push returns a future that is intentionally not awaited in callbacks
// ignore_for_file: discarded_futures

import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:better_player_plus/src/configuration/better_player_controller_event.dart';
import 'package:better_player_plus/src/core/better_player_utils.dart';
import 'package:better_player_plus/src/core/better_player_with_controls.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

///Widget which uses provided controller to render video player.
class BetterPlayer extends StatefulWidget {
  const new({super.key, required this.controller});

  factory network(String url, {BetterPlayerConfiguration? betterPlayerConfiguration}) => BetterPlayer(
    controller: BetterPlayerController(
      betterPlayerConfiguration ?? const BetterPlayerConfiguration(),
      betterPlayerDataSource: BetterPlayerDataSource(BetterPlayerDataSourceType.network, url),
    ),
  );

  factory file(String url, {BetterPlayerConfiguration? betterPlayerConfiguration}) => BetterPlayer(
    controller: BetterPlayerController(
      betterPlayerConfiguration ?? const BetterPlayerConfiguration(),
      betterPlayerDataSource: BetterPlayerDataSource(BetterPlayerDataSourceType.file, url),
    ),
  );

  final BetterPlayerController controller;

  @override
  State<BetterPlayer> createState() => _BetterPlayerState();
}

class _BetterPlayerState extends State<BetterPlayer> with WidgetsBindingObserver {
  BetterPlayerConfiguration get _betterPlayerConfiguration => widget.controller.betterPlayerConfiguration;

  bool _isFullScreen = false;

  ///State of navigator on widget created
  late NavigatorState _navigatorState;

  ///Flag which determines if widget has initialized
  bool _initialized = false;

  ///Subscription for controller events
  StreamSubscription<dynamic>? _controllerEventSubscription;

  ///Store the original system UI overlay style before entering fullscreen
  SystemUiOverlayStyle? _originalSystemUiOverlayStyle;

  /// Helper method to determine the appropriate SystemUiOverlayStyle based on theme
  SystemUiOverlayStyle _getSystemUiOverlayStyleFromTheme(BuildContext context) {
    final theme = Theme.of(context);

    // Check if there's an explicit style set in the app bar theme
    if (theme.appBarTheme.systemOverlayStyle != null) {
      return theme.appBarTheme.systemOverlayStyle!;
    }

    // Fallback to determining from theme brightness
    if (theme.brightness == Brightness.dark) {
      return SystemUiOverlayStyle
          .light; // Light status bar content for dark theme
    } else {
      return SystemUiOverlayStyle
          .dark; // Dark status bar content for light theme
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    if (!_initialized) {
      final navigator = Navigator.of(context);
      setState(() {
        _navigatorState = navigator;
      });
      _setup();
      _initialized = true;
    }
    super.didChangeDependencies();
  }

  Future<void> _setup() async {
    _controllerEventSubscription = widget.controller.controllerEventStream.listen(onControllerEvent);

    //Default locale
    var locale = const Locale('en', 'US');
    try {
      if (mounted) {
        final contextLocale = Localizations.localeOf(context);
        locale = contextLocale;
      }
    } on Exception catch (exception) {
      BetterPlayerUtils.log(exception.toString());
    }
    widget.controller.setupTranslations(locale);
  }

  @override
  void dispose() {
    ///If somehow BetterPlayer widget has been disposed from widget tree and
    ///full screen is on, then full screen route must be pop and return to normal
    ///state.
    if (_isFullScreen) {
      _navigatorState.maybePop();
      // A PiP-induced fullscreen changed none of these, so there is nothing
      // to restore (see _pushFullScreenWidget).
      if (!widget.controller.isFullScreenForPip) {
        WakelockPlus.disable();
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: _betterPlayerConfiguration.systemOverlaysAfterFullScreen,
        );
        SystemChrome.setPreferredOrientations(_betterPlayerConfiguration.deviceOrientationsAfterFullScreen);
      }
    }

    WidgetsBinding.instance.removeObserver(this);
    _controllerEventSubscription?.cancel();
    widget.controller.dispose();
    VisibilityDetectorController.instance.forget(Key('${widget.controller.hashCode}_key'));
    super.dispose();
  }

  @override
  void didUpdateWidget(BetterPlayer oldWidget) {
    if (oldWidget.controller != widget.controller) {
      _controllerEventSubscription?.cancel();
      _controllerEventSubscription = widget.controller.controllerEventStream.listen(onControllerEvent);
    }
    super.didUpdateWidget(oldWidget);
  }

  void onControllerEvent(BetterPlayerControllerEvent event) {
    switch (event) {
      case BetterPlayerControllerEvent.openFullscreen:
        onFullScreenChanged();
      case BetterPlayerControllerEvent.hideFullscreen:
        onFullScreenChanged();
      default:
        setState(() {});
    }
  }

  Future<void> onFullScreenChanged() async {
    final controller = widget.controller;
    if (controller.isFullScreen && !_isFullScreen) {
      _isFullScreen = true;
      controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.openFullscreen));
      await _pushFullScreenWidget(context);
    } else if (_isFullScreen) {
      Navigator.of(context, rootNavigator: true).pop();
      _isFullScreen = false;
      controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.hideFullscreen));
    }
  }

  @override
  Widget build(BuildContext context) =>
      BetterPlayerControllerProvider(controller: widget.controller, child: _buildPlayer());

  Widget _buildFullScreenVideo(
    BuildContext context,
    Animation<double> animation,
    BetterPlayerControllerProvider controllerProvider,
  ) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: Container(alignment: Alignment.center, color: Colors.black, child: controllerProvider),
  );

  AnimatedWidget _defaultRoutePageBuilder(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    BetterPlayerControllerProvider controllerProvider,
  ) => AnimatedBuilder(
    animation: animation,
    builder: (BuildContext context, Widget? child) => _buildFullScreenVideo(context, animation, controllerProvider),
  );

  Widget _fullScreenRoutePageBuilder(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final controllerProvider = BetterPlayerControllerProvider(controller: widget.controller, child: _buildPlayer());

    final routePageBuilder = _betterPlayerConfiguration.routePageBuilder;
    if (routePageBuilder == null) {
      return _defaultRoutePageBuilder(context, animation, secondaryAnimation, controllerProvider);
    }

    return routePageBuilder(context, animation, secondaryAnimation, controllerProvider);
  }

  Future<dynamic> _pushFullScreenWidget(BuildContext context) async {
    final TransitionRoute<void> route = PageRouteBuilder<void>(
      settings: const RouteSettings(),
      pageBuilder: _fullScreenRoutePageBuilder,
    );

    // Store the current system UI overlay style based on theme
    _originalSystemUiOverlayStyle = _getSystemUiOverlayStyleFromTheme(context);

    // A fullscreen entered for Android picture-in-picture only exists so the
    // video fills the PiP window. The activity is being pinned at that
    // moment, and a rotation, system UI or wakelock request landing inside
    // that window-manager transition wedges the system PiP controller, so
    // the route is pushed with none of the usual side effects and nothing is
    // restored when it pops.
    final bool forPip = widget.controller.isFullScreenForPip;

    if (!forPip) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      if (_betterPlayerConfiguration.autoDetectFullscreenDeviceOrientation) {
        final aspectRatio = widget.controller.videoPlayerController?.value.aspectRatio ?? 1.0;
        List<DeviceOrientation> deviceOrientations;
        if (aspectRatio < 1.0) {
          deviceOrientations = [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];
        } else {
          deviceOrientations = [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight];
        }
        await SystemChrome.setPreferredOrientations(deviceOrientations);
      } else {
        await SystemChrome.setPreferredOrientations(
          widget.controller.betterPlayerConfiguration.deviceOrientationsOnFullScreen,
        );
      }

      if (!_betterPlayerConfiguration.allowedScreenSleep) {
        await WakelockPlus.enable();
      }
    }

    if (context.mounted) {
      await Navigator.of(context, rootNavigator: true).push(route);
      _isFullScreen = false;
      widget.controller.backFromFullScreen();
    }

    if (forPip) {
      return;
    }

    // The wakelock plugins checks whether it needs to perform an action internally,
    // so we do not need to check Wakelock.isEnabled.
    await WakelockPlus.disable();

    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: _betterPlayerConfiguration.systemOverlaysAfterFullScreen,
    );
    await SystemChrome.setPreferredOrientations(_betterPlayerConfiguration.deviceOrientationsAfterFullScreen);
  }

  Widget _buildPlayer() {
    // Determine the appropriate system UI overlay style
    final systemUiOverlayStyle = _originalSystemUiOverlayStyle ??
        _getSystemUiOverlayStyleFromTheme(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemUiOverlayStyle,
        child: VisibilityDetector(
          key: Key("${widget.controller.hashCode}_key"),
          onVisibilityChanged: (VisibilityInfo info) =>
              widget.controller.onPlayerVisibilityChanged(info.visibleFraction),
          child: BetterPlayerWithControls(
            controller: widget.controller,
          ),
        ),
  );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    widget.controller.setAppLifecycleState(state);
  }
}

///Page route builder used in fullscreen mode.
typedef BetterPlayerRoutePageBuilder =
    Widget Function(
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      BetterPlayerControllerProvider controllerProvider,
    );
