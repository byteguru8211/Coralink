import 'package:coralink/core/strings.dart';
import 'package:coralink/core/theme.dart';
import 'package:coralink/core/utils.dart';
import 'package:coralink/domain/models.dart';
import 'package:coralink/presentation/widgets/chat_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Message message) => MaterialApp(
  theme: AppTheme.build(Brightness.dark),
  locale: const Locale('ru'),
  supportedLocales: AppStrings.supported,
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Scaffold(
    body: MessageBubble(
      message: message,
      myId: 'me',
      strings: AppStrings(const Locale('ru')),
    ),
  ),
);

void main() {
  testWidgets('sticker time stays hidden until the status drop is tapped', (
    tester,
  ) async {
    final createdAt = DateTime(2026, 1, 2, 3, 4);
    final message = Message(
      id: 'sticker-1',
      chatId: 'chat',
      senderId: 'me',
      kind: MessageKind.sticker,
      status: MessageStatus.delivered,
      createdAt: createdAt,
      meta: const {'sticker': 'wave'},
    );
    await tester.pumpWidget(_app(message));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(formatClock(createdAt)), findsNothing);
    await tester.tap(find.byIcon(Icons.water_drop_rounded));
    await tester.pump();
    expect(find.text(formatClock(createdAt)), findsOneWidget);
  });

  testWidgets('status drop changes from unread blue to read green', (
    tester,
  ) async {
    final delivered = Message(
      id: 'text-1',
      chatId: 'chat',
      senderId: 'me',
      text: 'hello',
      status: MessageStatus.delivered,
      createdAt: DateTime(2026),
    );
    await tester.pumpWidget(_app(delivered));
    await tester.pump(const Duration(milliseconds: 500));
    final unread = tester.widget<Icon>(find.byIcon(Icons.water_drop_rounded));
    expect(unread.color, const Color(0xFF63B3FF));

    final read = delivered.copyWith(status: MessageStatus.read);
    await tester.pumpWidget(_app(read));
    await tester.pump(const Duration(milliseconds: 500));
    final readDrop = tester.widget<Icon>(find.byIcon(Icons.water_drop_rounded));
    expect(readDrop.color, const Color(0xFF73E2B4));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });
}
