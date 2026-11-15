/// نام صداها در مانیفست لاتین است (مثلاً Dilara). این فایل نام را به
/// خط و زبان خودِ صدا برمی‌گرداند (مثلاً دلارام). برای زبان‌های لاتین‌نویس
/// (آلمانی، انگلیسی، ...) نام همان می‌ماند. اگر نامی در جدول نبود، همان نام
/// لاتین نمایش داده می‌شود.
const Map<String, Map<String, String>> _kNativeVoiceNames = {
  'fa': {'dilara': 'دلارام', 'farid': 'فرید'},
  'es': {'alvaro': 'Álvaro', 'elvira': 'Elvira'},
  'ar': {
    'zariyah': 'زارية', 'hamed': 'حامد', 'salma': 'سلمى', 'shakir': 'شاكر',
    'fatima': 'فاطمة', 'hamdan': 'حمدان', 'rana': 'رنا', 'bassel': 'باسل',
    'sana': 'سناء', 'taim': 'تيم', 'noura': 'نورة', 'fahed': 'فهد',
    'layla': 'ليلى', 'rami': 'رامي', 'amal': 'أمل', 'moaz': 'معاذ',
    'amany': 'أماني', 'laith': 'ليث', 'reem': 'ريم', 'hedi': 'هادي',
    'maryam': 'مريم', 'saleh': 'صالح', 'mouna': 'منى', 'jamal': 'جمال',
    'amina': 'أمينة', 'ismael': 'إسماعيل', 'iman': 'إيمان', 'omar': 'عمر',
    'aysha': 'عائشة', 'abdullah': 'عبدالله', 'ali': 'علي', 'laila': 'ليلى',
  },
  'ur': {'gul': 'گل', 'salman': 'سلمان', 'uzma': 'عظمیٰ', 'asad': 'اسد'},
  'ps': {'latifa': 'لطيفه', 'gulnawaz': 'ګل نواز'},
  'ru': {'svetlana': 'Светлана', 'dmitry': 'Дмитрий'},
  'uk': {'polina': 'Поліна', 'ostap': 'Остап'},
  'bg': {'kalina': 'Калина', 'borislav': 'Борислав'},
  'sr': {'sophie': 'Софија', 'nicholas': 'Никола'},
  'mk': {'marija': 'Марија', 'aleksandar': 'Александар'},
  'kk': {'aigul': 'Айгүл', 'daulet': 'Дәулет'},
  'mn': {'yesui': 'Есөөй', 'bataa': 'Батаа'},
  'zh': {
    'xiaoxiao': '晓晓', 'xiaoyi': '晓伊', 'yunjian': '云健', 'yunxi': '云希',
    'yunxia': '云夏', 'yunyang': '云扬', 'xiaobei': '晓北', 'xiaoni': '晓妮',
    'hiugaai': '曉佳', 'hiumaan': '曉曼', 'wanlung': '雲龍',
    'hsiaochen': '曉臻', 'hsiaoyu': '曉雨', 'yunjhe': '雲哲',
  },
  'ja': {
    'nanami': '七海', 'keita': '圭太', 'aoi': '碧衣', 'daichi': '大地',
    'mayu': '真由', 'naoki': '直紀', 'shiori': '志織',
  },
  'ko': {
    'sunhi': '선희', 'injoon': '인준', 'bongjin': '봉진', 'gookmin': '국민',
    'jimin': '지민', 'seohyeon': '서현', 'soonbok': '순복', 'yujin': '유진',
    'hyunsu': '현수',
  },
  'hi': {'swara': 'स्वरा', 'madhur': 'मधुर'},
  'mr': {'aarohi': 'आरोही', 'manohar': 'मनोहर'},
  'ne': {'hemkala': 'हेमकला', 'sagar': 'सागर'},
  'gu': {'dhwani': 'ધ્વનિ', 'niranjan': 'નિરંજન'},
  'kn': {'sapna': 'ಸಪ್ನಾ', 'gagan': 'ಗಗನ್'},
  'ml': {'sobhana': 'ശോഭന', 'midhun': 'മിഥുൻ'},
  'bn': {
    'tanishaa': 'তনিশা', 'bashkar': 'ভাস্কর', 'nabanita': 'নবনীতা',
    'pradeep': 'প্রদীপ',
  },
  'ta': {
    'pallavi': 'பல்லவி', 'valluvar': 'வள்ளுவர்', 'kumar': 'குமார்',
    'saranya': 'சரண்யா',
  },
  'te': {'shruti': 'శ్రుతి', 'mohan': 'మోహన్'},
  'si': {'thilini': 'තිළිණි', 'sameera': 'සමීර'},
  'he': {'hila': 'הילה', 'avri': 'אברי'},
  'el': {'athina': 'Αθηνά', 'nestoras': 'Νέστορας'},
  'th': {'premwadee': 'เปรมวดี', 'niwat': 'นิวัฒน์', 'achara': 'อัจฉรา'},
  'ka': {'eka': 'ეკა', 'giorgi': 'გიორგი'},
  'hy': {'anahit': 'Անահիտ', 'hayk': 'Հայկ'},
  'km': {'sreymom': 'ស្រីមុំ', 'piseth': 'ពិសិដ្ឋ'},
  'lo': {'keomany': 'ແກ້ວມະນີ', 'chanthavong': 'ຈັນທະວົງ'},
  'my': {'nilar': 'နီလာ', 'thiha': 'သီဟ'},
};

String localizedVoiceName({
  required String bareName,
  required String languageCode,
  required String voiceName,
}) {
  var lang = languageCode.trim().toLowerCase();
  if (lang.isEmpty) {
    final m = RegExp(r'^([a-zA-Z]{2,3})-').firstMatch(voiceName.trim());
    if (m != null) lang = m.group(1)!.toLowerCase();
  }
  final dash = lang.indexOf(RegExp(r'[-_]'));
  if (dash > 0) lang = lang.substring(0, dash);
  final table = _kNativeVoiceNames[lang];
  if (table == null) return bareName;
  final key = bareName
      .toLowerCase()
      .replaceAll(RegExp(r'multilingual', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^a-z]'), '');
  return table[key] ?? bareName;
}
