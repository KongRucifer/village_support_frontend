class VbCode {
  final String vbCode;
  final String nameLao;
  final String nameEng;
  final String provinceId;
  final String? provinceName;
  final String districtId;
  final String? districtName;
  final String? villageBankName;
  final String? foundingDate;
  final String? statusId;
  final int clientCount;
  final int accountOwnerCount;

  VbCode({
    required this.vbCode,
    required this.nameLao,
    required this.nameEng,
    required this.provinceId,
    this.provinceName,
    required this.districtId,
    this.districtName,
    this.villageBankName,
    this.foundingDate,
    this.statusId,
    this.clientCount = 0,
    this.accountOwnerCount = 0,
  });

  factory VbCode.fromJson(Map<String, dynamic> j) => VbCode(
        vbCode: (j['vbCode'] ?? '') as String,
        nameLao: (j['nameLao'] ?? '') as String,
        nameEng: (j['nameEng'] ?? '') as String,
        provinceId: (j['provinceId'] ?? '') as String,
        provinceName: j['provinceName'] as String?,
        districtId: (j['districtId'] ?? '') as String,
        districtName: j['districtName'] as String?,
        villageBankName: j['villageBankName'] as String?,
        foundingDate: j['foundingDate']?.toString(),
        statusId: j['statusId']?.toString(),
        clientCount: (j['clientCount'] ?? 0) as int,
        accountOwnerCount: (j['accountOwnerCount'] ?? 0) as int,
      );

  /// Column map for SQLite (snake_case).
  Map<String, dynamic> toDb() => {
        'vb_code': vbCode,
        'name_lao': nameLao,
        'name_eng': nameEng,
        'province_id': provinceId,
        'province_name': provinceName,
        'district_id': districtId,
        'district_name': districtName,
        'village_bank_name': villageBankName,
        'founding_date': foundingDate,
        'status_id': statusId,
        'client_count': clientCount,
        'account_owner_count': accountOwnerCount,
      };

  factory VbCode.fromDb(Map<String, dynamic> r) => VbCode(
        vbCode: r['vb_code'] as String,
        nameLao: (r['name_lao'] ?? '') as String,
        nameEng: (r['name_eng'] ?? '') as String,
        provinceId: (r['province_id'] ?? '') as String,
        provinceName: r['province_name'] as String?,
        districtId: (r['district_id'] ?? '') as String,
        districtName: r['district_name'] as String?,
        villageBankName: r['village_bank_name'] as String?,
        foundingDate: r['founding_date'] as String?,
        statusId: r['status_id'] as String?,
        clientCount: (r['client_count'] ?? 0) as int,
        accountOwnerCount: (r['account_owner_count'] ?? 0) as int,
      );
}
