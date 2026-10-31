import '../data/local_store.dart';
import '../domain/models.dart';

class EchoHit {
  const EchoHit(this.message, this.score);
  final Message message;
  final double score;
}

/// Local "echolocation": meaning-aware search without shipping message text to
/// a server. Combines stemming, a small synonym graph, token overlap and
/// character-trigram similarity, then ranks matches.
class EchoSearch {
  EchoSearch(this._store);

  final LocalStore _store;

  static const _stopWords = {
    'и', 'в', 'во', 'не', 'что', 'он', 'на', 'я', 'с', 'со', 'как', 'а', 'то',
    'все', 'она', 'так', 'его', 'но', 'да', 'ты', 'к', 'у', 'же', 'вы', 'за',
    'бы', 'по', 'только', 'ее', 'мне', 'было', 'вот', 'от', 'меня', 'еще',
    'нет', 'о', 'из', 'ему', 'теперь', 'когда', 'даже', 'ну', 'вдруг', 'ли',
    'если', 'уже', 'или', 'ни', 'быть', 'был', 'него', 'до', 'вас', 'нибудь',
    'опять', 'уж', 'вам', 'ведь', 'там', 'потом', 'себя', 'ничего', 'ей',
    'может', 'они', 'тут', 'где', 'есть', 'надо', 'ней', 'для', 'мы', 'тебя',
    'их', 'чем', 'была', 'сам', 'чтоб', 'без', 'будто', 'чего', 'раз', 'тоже',
    'себе', 'под', 'будет', 'ж', 'тогда', 'кто', 'этот', 'того', 'потому',
    'этого', 'какой', 'совсем', 'ним', 'здесь', 'этом', 'один', 'почти',
    'мой', 'тем', 'чтобы', 'нее', 'сейчас', 'были', 'куда', 'зачем', 'всех',
    'никогда', 'можно', 'при', 'наконец', 'два', 'об', 'другой', 'хоть',
    'после', 'над', 'больше', 'тот', 'через', 'эти', 'нас', 'про', 'всего',
    'них', 'какая', 'много', 'разве', 'три', 'эту', 'моя', 'впрочем', 'хорошо',
    'свою', 'этой', 'перед', 'иногда', 'лучше', 'чуть', 'том', 'нельзя',
    'такой', 'им', 'более', 'всегда', 'конечно', 'всю', 'между', 'the', 'a',
    'an', 'and', 'or', 'to', 'of', 'in', 'on', 'for', 'is', 'are', 'it', 'this',
    'that', 'with', 'as', 'at', 'be', 'was', 'were', 'i', 'you', 'we', 'they',
    'he', 'she', 'my', 'your', 'me', 'us', 'do', 'did', 'not', 'no', 'yes',
  };

  static const _synonyms = <List<String>>[
    ['привет', 'здравствуй', 'хай', 'приветик', 'салют'],
    ['пока', 'прощай', 'до', 'свидания'],
    ['спасибо', 'благодарю', 'спс'],
    ['встреча', 'созвон', 'митинг', 'встретиться', 'созвониться', 'созвонимся',
     'созвонились', 'созвонился', 'созвоним', 'встретимся', 'встречаемся',
     'встречались', 'встречаться', 'созвоном'],
    ['работа', 'офис', 'проект', 'задача'],
    ['деньги', 'зарплата', 'оплата', 'перевод'],
    ['еда', 'обед', 'ужин', 'завтрак', 'поесть'],
    ['время', 'час', 'минута', 'срок'],
    ['дом', 'квартира', 'жилье'],
    ['любовь', 'люблю', 'любить'],
    ['фото', 'фотография', 'снимок', 'картинка', 'изображение'],
    ['hello', 'hi', 'hey'],
    ['thanks', 'thank', 'grateful'],
    ['meeting', 'call', 'sync'],
    ['money', 'payment', 'salary'],
    ['food', 'lunch', 'dinner'],
    ['home', 'house', 'flat'],
    ['photo', 'image', 'picture'],
  ];

  static final Map<String, String> _synonymIndex = () {
    final index = <String, String>{};
    for (final group in _synonyms) {
      final key = _stem(group.first);
      for (final word in group) {
        index[word] = key;
        index[_stem(word)] = key;
      }
    }
    return index;
  }();

  static String _normalize(String input) =>
      input.toLowerCase().replaceAll('ё', 'е').replaceAll(RegExp(r'[^a-zа-я0-9\s]+'), ' ');

  static List<String> _tokens(String input) {
    return _normalize(input)
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 2 && !_stopWords.contains(w))
        .map(_stem)
        .toList();
  }

  static String _stem(String word) {
    const endings = [
      'ирования', 'ирование', 'ования', 'ование', 'ировать', 'ываться',
      'ами', 'ями', 'ого', 'его', 'ому', 'ему', 'ыми', 'ими', 'ать', 'ять',
      'ить', 'еть', 'ует', 'ают', 'яют', 'ится', 'ться', 'ешь', 'ете', 'ите',
      'ах', 'ях', 'ов', 'ев', 'ый', 'ий', 'ая', 'яя', 'ое', 'ее', 'ую', 'юю',
      'ами', 'ами', 'ing', 'ed', 'es', 's', 'ы', 'и', 'а', 'я', 'у', 'ю', 'е', 'о',
    ];
    for (final ending in endings) {
      if (word.length > ending.length + 3 && word.endsWith(ending)) {
        return word.substring(0, word.length - ending.length);
      }
    }
    return word;
  }

  static String _canonical(String token) => _synonymIndex[token] ?? token;

  static double _trigramSimilarity(String a, String b) {
    if (a == b) return 1;
    if (a.length < 3 || b.length < 3) return 0;
    final gramsA = <String>{for (var i = 0; i < a.length - 2; i++) a.substring(i, i + 3)};
    final gramsB = <String>{for (var i = 0; i < b.length - 2; i++) b.substring(i, i + 3)};
    if (gramsA.isEmpty || gramsB.isEmpty) return 0;
    final common = gramsA.intersection(gramsB).length;
    return (2 * common) / (gramsA.length + gramsB.length);
  }

  double score(String query, String text) {
    final queryTokens = _tokens(query);
    if (queryTokens.isEmpty) return 0;
    final textTokens = _tokens(text);
    if (textTokens.isEmpty) return 0;
    var score = 0.0;
    final textCanonical = textTokens.map(_canonical).toSet();
    for (final token in queryTokens) {
      final canonical = _canonical(token);
      if (textTokens.contains(token)) {
        score += 1.0;
      } else if (textCanonical.contains(canonical)) {
        score += 0.75;
      } else {
        var best = 0.0;
        for (final candidate in textTokens) {
          final similarity = _trigramSimilarity(token, candidate);
          if (similarity > best) best = similarity;
        }
        if (best > 0.35) score += best * 0.8;
      }
    }
    final normalizedQuery = _normalize(query).trim();
    if (normalizedQuery.length > 2 && _normalize(text).contains(normalizedQuery)) {
      score += 0.6;
    }
    return score / queryTokens.length;
  }

  Future<List<EchoHit>> search(String query, {int limit = 40}) async {
    final messages = await _store.getAllMessages(limit: 4000);
    final hits = <EchoHit>[];
    for (final message in messages) {
      final value = score(query, message.text);
      if (value >= 0.30) hits.add(EchoHit(message, value));
    }
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.message.createdAt.compareTo(a.message.createdAt);
    });
    return hits.take(limit).toList();
  }
}
