import 'package:flutter/material.dart';

import '../../game_ui_plugin.dart';
import 'fantasy_wars_game_screen.dart';

class FantasyWarsUiPlugin implements GameUiPlugin {
  const FantasyWarsUiPlugin();

  @override
  String get gameType => 'fantasy_wars_artifact';

  @override
  String get displayName => '판타지 워즈: 성유물 쟁탈전';

  @override
  int get minPlayers => 9;

  @override
  Widget buildScreen(BuildContext context, String sessionId) {
    return FantasyWarsGameScreen(sessionId: sessionId);
  }
}
