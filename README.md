# CocoLauncher iOS

Launcher Minecraft: Java Edition cho iPhone/iPad, cấu hình sẵn cho server **Coco Cobblemon**.
Đây là bản sửa (fork) của [Angel Aura Amethyst](https://github.com/AngelAuraMC/Amethyst-iOS), vốn phát triển từ [PojavLauncher](https://github.com/PojavLauncherTeam/PojavLauncher_iOS). Toàn bộ mã nguồn công khai theo giấy phép **GNU GPLv3** (xem [LICENSE](LICENSE)).

A Minecraft: Java Edition launcher for iPhone and iPad, preconfigured for the **Coco Cobblemon** server. Fork of Angel Aura Amethyst (based on PojavLauncher), licensed under the GNU GPLv3.

## Cài đặt / Install

- Nguồn SideStore (SideStore source): `https://coconubs.github.io/CocoLauncher-iOS/source.json`
- Trang cài đặt: https://coconubs.github.io/CocoLauncher-iOS/
- File IPA: trang [Releases](https://github.com/Coconubs/CocoLauncher-iOS/releases). IPA không ký sẵn; SideStore (hoặc iloader) ký lại bằng Apple ID của người chơi khi cài.

Điều kiện:
- Cần **tài khoản Microsoft đã mua Minecraft: Java Edition** để tải game lần đầu. CocoLauncher giữ nguyên cơ chế kiểm quyền sở hữu và chế độ Demo của Amethyst. Coco không phát file game của Mojang.
- Cần JIT (StikDebug hoặc cách khác mà Amethyst hỗ trợ), cần cài bằng chứng chỉ development (SideStore, AltStore, iloader). Chứng chỉ phân phối/doanh nghiệp (ESign, KSign...) không chạy được.
- Khuyên máy 8 GB RAM (gói Coco Lite có khoảng 127 mod).

Requirements: a Microsoft account that owns Minecraft: Java Edition (needed for the first download; the Amethyst ownership check and Demo mode are unchanged), JIT, and a development-signed install (SideStore, AltStore, iloader). Devices with 8 GB RAM are recommended.

## Những gì đã thay đổi so với Amethyst / Changes from Amethyst

Bản gốc: Amethyst-iOS nhánh `main`, commit [`f98c413`](https://github.com/AngelAuraMC/Amethyst-iOS/commit/f98c4133c72d39e06ceac42b57cc4477c52105fc) (4/10/2026). Các thay đổi bắt đầu từ 07/11/2026; chi tiết từng thay đổi xem lịch sử commit.

| Phần | Thay đổi |
|---|---|
| Nhận diện | Tên CocoLauncher, bundle id `dev.coconubs.cocolauncher.ios`, URL scheme `cocolauncher`, phiên bản 1.0.0, icon CocoLauncher. Tên file chạy `AngelAuraAmethyst` giữ nguyên (phần Java gọi theo tên này). |
| Profile Coco | Lần đầu mở app tự tạo và chọn profile "Coco Cobblemon": `fabric-loader-0.18.4-1.21.1`, thư mục game `./CocoLite`, renderer MobileGlues. File version của Fabric (từ meta.fabricmc.net) đóng sẵn trong app. |
| Gói Coco Lite | Khi chơi profile Coco, app đồng bộ gói theo manifest công khai của bản Android (`Coconubs/cocolauncher-pack`, release `android`): kiểm SHA-1 từng file, chặn đường dẫn có `..`, chỉ tải file nằm trên release của `Coconubs/cocolauncher-pack`, file kiểu "seed" (config, `options.txt`, `servers.dat`) chỉ đặt lần đầu, mod không còn trong gói thì xoá. Bước này chạy SAU phần file Minecraft, vốn vẫn qua bước kiểm tài khoản gốc của Amethyst. |
| Mặc định | Renderer MobileGlues, tắt Auto RAM, RAM 3072 MB với máy 8 GB (2560 MB máy 6 GB, 2048 MB máy khác). Chỉ đóng gói Java 21. |
| Giao diện | Hộp "Waiting for JIT" có nút Huỷ. Màn chọn tài khoản giải thích điều kiện tài khoản (tiếng Việt và tiếng Anh). Tab News mở trang hướng dẫn Coco. Ẩn mục "Execute .jar". |
| Đã gỡ | Javaagent Cosmetica (`arc_dns_injector.jar`, chuyển tra cứu DNS sang IP 23.95.137.176) và nút bật nó. Thư viện ballpa1n HostManager (không có giấy phép); tên máy nay lấy bằng `sysctl hw.machine`. |
| Java | Makefile tải Java 21 từ release [`jre-mirror`](https://github.com/Coconubs/CocoLauncher-iOS/releases/tag/jre-mirror) của repo này và kiểm SHA-256 (máy chủ gốc `assets.angelauramc.dev` không còn phân giải được). Không xoá các file giấy phép của OpenJDK nữa. |
| CI | Workflow gốc chạy trên máy Mac riêng của nhóm Amethyst (`runs-on: J316sAP`). Bản này build trên máy macOS của GitHub (`macos-26`), tự cài ldid, GNU make, JDK 8; khi có release thì gắn IPA vào release và cập nhật nguồn SideStore trên GitHub Pages. |

Giữ nguyên (không sửa): cơ chế kiểm quyền sở hữu Minecraft, tài khoản Demo, đăng nhập Microsoft, cách bật JIT (StikDebug/SideStore/TrollStore), các cảnh báo khi cài bằng chứng chỉ không hỗ trợ.

## Build

Chỉ build được trên macOS (Xcode có iOS SDK). Cách CI làm (xem `.github/workflows/build.yml`):

```sh
brew install ldid make
# JDK 8 (ví dụ Azul Zulu 8)
git submodule update --init --recursive
gmake -j"$(sysctl -n hw.ncpu)" package PLATFORM=2 BOOTJDK="$JAVA_HOME/bin"
# kết quả: artifacts/CocoLauncher-<version>-ios.ipa
```

File `Amethyst.xcodeproj` là của bản gốc và chưa được cập nhật theo các thay đổi ở trên; hãy dùng Makefile.

## Ghi công / Credits

- [Angel Aura Amethyst](https://github.com/AngelAuraMC/Amethyst-iOS) (AngelAuraMC) và [PojavLauncher](https://github.com/PojavLauncherTeam) (bản quyền PojavLauncher 2021, Tran Hoang Khanh Duy) — GPLv3.
- Những người đóng góp cho Amethyst: @crystall1nedev, @khanhduytran0, @artdeell, @Mathius-Boulay, @zhuowei, @jkcoxson, @Diatrus và cộng đồng.
- Java runtime: OpenJDK do AngelAuraMC build cho iOS ([angelauramc-openjdk-build](https://github.com/AngelAuraMC/angelauramc-openjdk-build)), GPLv2 kèm Classpath Exception. Bản sao, giấy phép và mã nguồn: release `jre-mirror`.
- Coco Cobblemon không liên quan tới Mojang hay Microsoft. Minecraft là thương hiệu của Mojang AB.

## Thành phần bên thứ ba / Third party components

Như bản gốc Amethyst (trừ ballpa1n HostManager và Cosmetica DNS injector đã gỡ):

- [Caciocavallo](https://github.com/PojavLauncherTeam/caciocavallo): [GNU GPLv2](https://github.com/PojavLauncherTeam/caciocavallo/blob/master/LICENSE).
- [jsr305](https://code.google.com/p/jsr-305): [BSD 3-Clause](http://opensource.org/licenses/BSD-3-Clause).
- [Boardwalk](https://github.com/zhuowei/Boardwalk): [Apache 2.0](https://github.com/zhuowei/Boardwalk/blob/master/LICENSE).
- [GL4ES](https://github.com/ptitSeb/gl4es) by @lunixbochs @ptitSeb: [MIT](https://github.com/ptitSeb/gl4es/blob/master/LICENSE).
- [Mesa 3D Graphics Library](https://gitlab.freedesktop.org/mesa/mesa): [MIT](https://docs.mesa3d.org/license.html).
- [MetalANGLE](https://github.com/khanhduytran0/metalangle) by @kakashidinho and ANGLE team: [BSD 2.0](https://github.com/kakashidinho/metalangle/blob/master/LICENSE).
- [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues): [LGPL-2.1](https://github.com/MobileGL-Dev/MobileGlues/blob/main/LICENSE).
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK): [Apache 2.0](https://github.com/KhronosGroup/MoltenVK/blob/master/LICENSE).
- [openal-soft](https://github.com/kcat/openal-soft): [LGPLv2](https://github.com/kcat/openal-soft/blob/master/COPYING).
- OpenJDK (Java runtime): [GNU GPLv2 with Classpath Exception](https://openjdk.org/legal/gplv2+ce.html).
- [LWJGL3](https://github.com/PojavLauncherTeam/lwjgl3): [BSD-3](https://github.com/LWJGL/lwjgl3/blob/master/LICENSE.md).
- [LWJGLX](https://github.com/PojavLauncherTeam/lwjglx) (LWJGL2 API compatibility layer for LWJGL3): unknown license.
- [DBNumberedSlider](https://github.com/khanhduytran0/DBNumberedSlider): [Apache 2.0](https://github.com/immago/DBNumberedSlider/blob/master/LICENSE).
- [fishhook](https://github.com/khanhduytran0/fishhook): [BSD-3](https://github.com/facebook/fishhook/blob/main/LICENSE).
- [AFNetworking](https://github.com/AFNetworking/AFNetworking): [MIT](https://github.com/AFNetworking/AFNetworking/blob/master/LICENSE).
- [shaderc](https://github.com/khanhduytran0/shaderc): [Apache 2.0](https://github.com/google/shaderc/blob/main/LICENSE).
- [NRFileManager](https://github.com/mozilla-mobile/firefox-ios/tree/b2f89ac40835c5988a1a3eb642982544e00f0f90/ThirdParty/NRFileManager): [MPL-2.0](https://www.mozilla.org/en-US/MPL/2.0).
- [AltKit](https://github.com/rileytestut/AltKit).
- [UnzipKit](https://github.com/abbeycode/UnzipKit): [BSD-2](https://github.com/abbeycode/UnzipKit/blob/master/LICENSE).
- [DyldDeNeuralyzer](https://github.com/xpn/DyldDeNeuralyzer): bypasses Library Validation for loading external runtime.
- Thanks to [MCHeads](https://mc-heads.net) for providing Minecraft avatars.
