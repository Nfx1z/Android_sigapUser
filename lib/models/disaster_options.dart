// Daftar jenis bencana & tingkat kerusakan — HARUS SAMA dengan firmware UT
// dan dengan salinan yang sama persis di proyek sigap_admin.
const List<Map<String, dynamic>> kDisasterOptions = [
  {'code': 0, 'name': 'Gempa Bumi'},
  {'code': 1, 'name': 'Banjir'},
  {'code': 2, 'name': 'Tanah Longsor'},
  {'code': 3, 'name': 'Kebakaran'},
  {'code': 4, 'name': 'Kebocoran Gas'},
  {'code': 5, 'name': 'Lain-Lainnya'},
];

const List<Map<String, dynamic>> kDestructionOptions = [
  {'code': 0, 'name': 'Ringan'},
  {'code': 1, 'name': 'Menengah'},
  {'code': 2, 'name': 'Besar'},
  {'code': 3, 'name': 'Masif'},
  {'code': 4, 'name': 'Unknown'},
];

String disasterNameFromCode(dynamic code) {
  final match = kDisasterOptions.firstWhere(
        (e) => e['code'] == code,
    orElse: () => {'name': 'Tidak diketahui'},
  );
  return match['name'];
}

String destructionNameFromCode(dynamic code) {
  final match = kDestructionOptions.firstWhere(
        (e) => e['code'] == code,
    orElse: () => {'name': 'Tidak diketahui'},
  );
  return match['name'];
}