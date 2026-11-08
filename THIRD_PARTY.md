# Ghi công và thành phần bên thứ ba / Credits and third party components

## Ghi công / Credits

- [Angel Aura Amethyst](https://github.com/AngelAuraMC/Amethyst-iOS) (AngelAuraMC) và [PojavLauncher](https://github.com/PojavLauncherTeam) (bản quyền PojavLauncher 2021, Tran Hoang Khanh Duy) — GPLv3.
- Những người đóng góp cho Amethyst: @crystall1nedev, @khanhduytran0, @artdeell, @Mathius-Boulay, @zhuowei, @jkcoxson, @Diatrus và cộng đồng.
- Java runtime: OpenJDK do AngelAuraMC build cho iOS ([angelauramc-openjdk-build](https://github.com/AngelAuraMC/angelauramc-openjdk-build)), GPLv2 kèm Classpath Exception. Bản sao, giấy phép và mã nguồn: release `jre-mirror`.
- Cảm ơn / Thanks to [Prisma Minecraft iOS Launcher](https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher) (Gsjsjzhznsz; nhánh từ Air và [herbrine8403](https://github.com/herbrine8403)), bản v5.1.0, GPLv3. CocoLauncher học từ mã của họ các ý tưởng: thư mục cache shader cho MobileGlues (`MG_DIR_PATH`), tải song song nhiều kết nối hơn, ghi log crash JVM, giữ tắt vsync. Mã trong CocoLauncher là tự viết lại, không chép nguyên văn. / Ideas reimplemented from Prisma: MobileGlues shader cache folder, more parallel downloads, JVM crash logs, vsync guard.
- Cảm ơn / Thanks to [Amethyst-iOS-25](https://github.com/catsruledogs/Amethyst-iOS-25) (catsruledogs, GPLv3) và những người đóng góp: Ynnyny, DuyAnh662, T1k-T1k, NNSJ123, bcats4coding, jungwuk-ryu. Đã tham khảo cách họ làm tài khoản Local khi thiết kế luồng tài khoản Local của CocoLauncher. / Their local account flow was used as a reference.
- Cảm ơn / Thanks to [GetMoreRam](https://github.com/hugeBlack/GetMoreRam) (hugeBlack) và [StosSign](https://github.com/stossy11/StosSign) (Stossy11): ý tưởng và cách làm "Mở khoá RAM" (bật Increased Memory Limit cho app đã sideload). CocoLauncher không chép mã của họ (repo chưa ghi giấy phép); phần này tự viết lại trên isideload. / Idea and flow of the in-app "Unlock RAM"; no code copied (no license), reimplemented on isideload.
- [isideload](https://github.com/nab138/isideload) (nab138, thư viện của iloader): MIT. Dùng trong `Natives/cocoram` để đăng nhập Apple ID và bật Increased Memory Limit. Thư viện này dùng lại kết quả của [Sideloader](https://github.com/Dadoum/Sideloader) và [apple-codesign-quick](https://github.com/Dadoum/apple-codesign-quick) (Dadoum), [idevice](https://github.com/jkcoxson/idevice) (jkcoxson), [Impactor](https://github.com/claration/Impactor) (claration). Máy chủ anisette mặc định: ani.iloader.app.
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
