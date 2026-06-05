class SystemUser {
  final int id;
  final String userName;
  final List<String> roles;

  /// JWT access token. Non-final: AuthRepository ສາມາດ update ໄດ້
  /// ຫຼັງ silent refresh ໂດຍ user ບໍ່ຮູ້ຕົວ.
  String token;

  SystemUser({
    required this.id,
    required this.userName,
    required this.roles,
    required this.token,
  });

  factory SystemUser.fromLoginResponse(Map<String, dynamic> json) {
    final user = (json['user'] ?? {}) as Map<String, dynamic>;
    return SystemUser(
      id: (user['id'] ?? 0) as int,
      userName: (user['userName'] ?? '') as String,
      roles: ((user['roles'] ?? []) as List).map((e) => e.toString()).toList(),
      token: (json['accessToken'] ?? '') as String,
    );
  }

  factory SystemUser.fromCache(Map<String, dynamic> row, {String token = ''}) {
    return SystemUser(
      id: (row['id'] ?? 0) as int,
      userName: (row['user_name'] ?? '') as String,
      roles: ((row['roles'] ?? '') as String)
          .split(',')
          .where((e) => e.trim().isNotEmpty)
          .toList(),
      token: token,
    );
  }
}
