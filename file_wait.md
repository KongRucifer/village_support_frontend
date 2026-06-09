ລໍບໍ່ດົນ — ~1–3 ວິນາທີ ເທົ່ານັ້ນ ຖ້າ app ຍັງເປີດຢູ່.

ໄລຍະເວລາ sync ຕາມສະຖານະ app
ສະຖານະ	trigger	ລໍດົນປານໃດ
app ເປີດຢູ່ + ເປີດ internet	ConnectivityListener ໃນ dashboard_screen.dart:48 ຍິງທັນທີ	~1–3 ວິ
app ໃນ background (ບໍ່ kill) + ເປີດ internet	ເມື່ອ resume ກັບ foreground → didChangeAppLifecycleState ຍິງ	~1–3 ວິ ຫຼັງ resume
app ຖືກ kill ໝົດ	WorkManager ຍິງທຸກ ~15 ນາທີ (ຕ້ອງ internet ດ້ວຍ)	ສູງສຸດ 15 ນາທີ
ກໍລະນີຂອງເຈົ້າ (app ເປີດ)

ເປີດ internet  →  ConnectivityListener ຮູ້ທັນທີ
                →  sync.sync(token)  ← incremental, ດຶງສະເພາະທີ່ປ່ຽນ
                →  replaceTodayCheckins()  ← ລຶບ row ທີ່ server ໄດ້ຍ້າຍໄປ yesterday
                →  SQLite ຮູ້ຂໍ້ມູນໃໝ່ ✅
ປິດ internet ທັນທີ ຫຼັງ 1–3 ວິ = sync ສຳເລັດແລ້ວ → ສະແກນໄດ້ໂດຍໄດ້.

ຈຸດສຳຄັນ
ບໍ່ຕ້ອງລໍ 15 ນາທີ — 15 ນາທີ ແມ່ນ WorkManager ສຳລັບ app ທີ່ kill ໝົດ ເທົ່ານັ້ນ
Incremental sync ດຶງຂໍ້ມູນໜ້ອຍ (ສະເພາະ row ທີ່ synchronized >= lastSync) → ໄວ, ສຳເລັດໄດ້ເຖິງ internet ເປີດ ສັ້ນ 2–3 ວິ
Check-in rows ສົ່ງ ທຸກ row ຂອງມື້ນີ້ ຈາກ server ສະເໝີ → replaceTodayCheckins ລຶບ row ເກົ່າ, ໃສ່ row ໃໝ່ = ຂໍ້ມູນຕົງ server