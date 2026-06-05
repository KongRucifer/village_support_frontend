import '../repositories/auth_repository.dart';
import '../repositories/village_repository.dart';
import 'api_client.dart';
import 'connectivity_service.dart';
import 'local_db.dart';
import 'secure_storage_service.dart';
import 'sync_service.dart';

/// ຕົວ service locator ທີ່ share instance ດຽວໃນ app ທັງໝົດ.
class AppServices {
  AppServices._();
  static final AppServices instance = AppServices._();

  final ApiClient api = ApiClient();
  final LocalDb db = LocalDb.instance;
  final ConnectivityService connectivity = ConnectivityService();

  // SecureStorageService ສຳລັບ JWT token — ໃຊ້ OS Keychain/Keystore.
  final SecureStorageService secureStorage = SecureStorageService();

  late final AuthRepository auth = AuthRepository(
    api: api,
    db: db,
    connectivity: connectivity,
    secureStorage: secureStorage,
  );
  late final VillageRepository village =
      VillageRepository(api: api, db: db, connectivity: connectivity);
  late final SyncService sync =
      SyncService(api: api, db: db, connectivity: connectivity);
}
