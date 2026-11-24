import 'package:coralink/app/dependencies.dart';
import 'package:coralink/app/session.dart';
import 'package:coralink/core/strings.dart';
import 'package:coralink/core/theme.dart';
import 'package:coralink/domain/models.dart';
import 'package:coralink/presentation/pet_controller.dart';
import 'package:coralink/presentation/screens/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePetController extends PetController {
  _FakePetController(super.chatId);

  @override
  PetUiState build() => const PetUiState();
}

class _FakeSessionController extends SessionController {
  @override
  SessionState build() => const SessionState(
    status: SessionStatus.authenticated,
    user: User(id: 'me', phone: '', name: 'Me'),
  );
}

void main() {
  testWidgets('personal pet form is visible inside the home indexed stack', (
    tester,
  ) async {
    final strings = AppStrings(const Locale('ru'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          petProvider(
            'personal:me',
          ).overrideWith(() => _FakePetController('personal:me')),
          sessionProvider.overrideWith(_FakeSessionController.new),
          stringsProvider.overrideWithValue(strings),
        ],
        child: MaterialApp(
          theme: AppTheme.build(Brightness.dark),
          locale: const Locale('ru'),
          supportedLocales: AppStrings.supported,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const IndexedStack(
            index: 2,
            children: [SizedBox(), SizedBox(), PersonalPetScreen(), SizedBox()],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Кого будем растить?'), findsOneWidget);
  });
}
