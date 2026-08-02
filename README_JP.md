# mulesoft.nix

[English](./README.md) | 日本語

MuleSoft のツールを NixOS 向けにパッケージする Nix flake です。

| パッケージ | 内容 |
|---|---|
| `anypoint-studio` | MuleSoft の Eclipse ベース IDE |
| `advanced-rest-client` | ARC。MuleSoft のデスクトップ HTTP クライアント |

どちらもソースからのビルドではありません。上流はビルド済みのツリーを配布しており、
作業の中身はいずれも、それを nixpkgs のライブラリで、かつ `/nix/store` から
動かすことです。

## 使い方

Anypoint Studio はプロプライエタリなので、利用側で
`nixpkgs.config.allowUnfree = true;` が必要です。Advanced REST Client は
Apache-2.0 なので特別な設定は要りません。

### flake input として

```nix
{
  inputs.mulesoft = {
    url = "github:solitarywalker/mulesoft.nix";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-utils.follows = "flake-utils";
  };
}
```

パッケージを直接使う場合:

```nix
environment.systemPackages = with inputs.mulesoft.packages.${pkgs.system}; [
  anypoint-studio
  advanced-rest-client
];
```

overlay 経由で `pkgs.anypoint-studio` / `pkgs.advanced-rest-client` として使う場合:

```nix
nixpkgs.overlays = [ inputs.mulesoft.overlays.default ];
```

### インストールせずに試す

```console
$ nix run github:solitarywalker/mulesoft.nix                       # Anypoint Studio
$ nix run github:solitarywalker/mulesoft.nix#advanced-rest-client
```

# Anypoint Studio

配布物は約 2.2 GB の Linux 向け tarball で、Temurin JDK と Equo Chromium (CEF) を
同梱したビルド済みの Eclipse 製品です。コンパイルするものは何もなく、作業の中身は
その一式を nixpkgs のライブラリで動かすことと、**読み取り専用ディレクトリからの
起動を拒否するアプリケーションを `/nix/store` から動かすこと**です。

## 実行時にできるディレクトリ

| パス | 内容 |
|---|---|
| `$XDG_DATA_HOME/anypoint-studio/<version>/install` | Studio から見えるインストール先。store へのシンボリックリンク群と、1 つだけ実体コピー（後述） |
| `$XDG_DATA_HOME/anypoint-studio/<version>/configuration` | Equinox の configuration area と OSGi バンドルキャッシュ |
| `$XDG_DATA_HOME/anypoint-studio/<version>/p2` | p2 プロファイルレジストリ |
| `~/AnypointStudio/studio-workspace` | 既定のワークスペース（上流の既定値のまま） |

先頭のディレクトリは store のパスが変わるたびに作り直され、1 分ほどかかります。
ユーザーのデータは入っていない（ワークスペースは別の場所）ので、消しても常に安全
です。Studio が起動しなくなったらまずこれを消してください。

## パッケージがしていること

### インストールディレクトリが書き込み可能でなければならない

`org.mule.tooling.utils.lifecycle.LifeCycleManager#postContextCreate` が

```java
new File(Platform.getInstallLocation().getURL().toURI()).canWrite()
```

を実行し、`false` なら **Exit ボタンしかない**モーダルを出して `System.exit(-1)`
します。無視して先に進める類の警告ではありません。

判定はインストールディレクトリ自身に対する `canWrite()` 1 回だけで、再帰でもなく、
配下のファイルは一切見ません。つまりインストール先は「書き込み可能なディレクトリで
ありさえすればよく」、中身は store のままで構いません。そこで launcher は、store の
トップレベル項目へのシンボリックリンクだけを並べたユーザーごとのディレクトリを作り、
それを install area として Equinox に渡します。コピーは発生しません。

`-install` は明示的に渡す必要があります。そのディレクトリの中にランチャを置いて起動
する方法では駄目でした。ランチャは startup jar の位置から install area を求める際に
パスを正規化するので、`plugins/` を辿って store に戻ってしまい、またあのダイアログが
出ます。

`-configuration` はさらに Equinox の書き込み先をそのディレクトリの外へ移します。
`config.ini` に `eclipse.p2.data.area=@config.dir/../p2` とあるので、configuration を
1 階層下に置くことで p2 もその隣に落ち、中の読み取り専用な `p2` シンボリックリンクを
踏まずに済みます。

### 同梱 Mule ランタイムも書き込み可能でなければならない

設計時にプロジェクトを動かす際、ツール側は
`plugins/org.mule.tooling.server.*/mule` を自分のデータ領域へコピーします。しかも
**属性を保持したまま**コピーします。store から取ると 444 のツリーができ、それに
書き込もうとして失敗します:

```
MuleControllerException: Error while initializing wrapper conf...
Caused by: java.nio.file.AccessDeniedException: …/conf/wrapper.conf
```

ランタイムインスタンスは `Instance.invalid` になります。そのためこのバンドルだけは
store から実体コピーし（約 470 MB、ビルドごとに 1 回）、コピー元を 644 にしています。
兄弟の `org.mule.tooling.server.*.jar` は普通の jar なのでシンボリックリンクのままです。

### 同梱 JDK はそのまま使う

上流の `AnypointStudio.ini` は `-vm` を
`plugins/org.mule.tooling.jdk.linux.x86_64_*` に向けており、これは触っていません。
Eclipse の JustJ のような単なる同梱ランタイムではないからです。
`configuration/org.eclipse.equinox.simpleconfigurator/bundles.info` がこれを OSGi
バンドル `org.mule.tooling.jdk.linux.x86_64` として登録していて、ツール側はそこから
解決して設計時 Mule ランタイムを起動します（起動のたびにログへ
`Default JRE set: org.mule.tooling.jdk.linux.x86_64` が出ます）。`pkgs.jdk17` に
差し替えると `-vm` は直ってもそのバンドルが宙に浮くので、Temurin 17.0.12 のツリーごと
`autoPatchelfHook` に通しています。

### ネイティブライブラリ

ディスク上にある ELF は `autoPatchelfHook` が処理します。SWT のネイティブは対象外
です。`org.eclipse.swt.gtk.linux.x86_64_*.jar` の**中**に入っていて、初回起動時に
`~/.swt` へ展開されるため、patchelf が見られる時点には存在しません。これらと、SWT や
CEF が soname で `dlopen` するライブラリは、ラッパーの `LD_LIBRARY_PATH` で解決させて
います。GTK まわりの環境（GSettings スキーマ、gdk-pixbuf のローダキャッシュ、GIO
モジュール）は `wrapGAppsHook3` が用意します。

patch の前に、JNA と Tanuki のバンドルから Linux x86-64 以外のネイティブを削除して
います。どちらも実行時に名前でネイティブを選ぶので他は不要ですし、
`autoPatchelfHook` は ELF のマシンタイプだけで対象を決めるため、Solaris や FreeBSD の
x86-64 バイナリ（マシンは同じで OSABI が違う）に踏み込み、patchelf に拒否されて落ちます。

### ダウンロード

```
https://www.mulesoft.com/downloads/studio/latest/AnypointStudio-<version>-linux64.tar.gz
```

前段の Akamai が curl の既定 User-Agent を 403 で弾きます。ブラウザの User-Agent だけ
でも弾かれるので、User-Agent と `Referer` の両方が必要です。`fetchurl` の
`curlOptsList` で渡しています。CDN の背後にある `mule-studio` の S3 バケットは匿名で
読めないため、ミラーはありません。

## 既知の制限

- **Studio へのソフトウェア追加**（Help → Install New Software、および Studio 自身の
  アップデータ）は `plugins/` へ書き込むので失敗します。`plugins/` は store への
  シンボリックリンクです。Exchange からのコネクタ追加は影響を受けません（あれは
  プロジェクトの `pom.xml` に Maven 依存を書くだけで、インストール先は触りません）。
- 同じ理由で **`AnypointStudio.ini` を編集した JVM 調整**もできません。コマンドライン
  から渡してください。例: `anypoint-studio -vmargs -Xmx4g`
- x86-64 Linux のみです。上流は aarch64 macOS 版も出していますが、ここでは扱っていません。

# Advanced REST Client

公式の Linux 向け `.deb`（**17.0.9**、2022 年 3 月）から再パッケージしています。
プロジェクトは終了しリポジトリもアーカイブ済みなので、これが最後のリリースです。

データはすべて `~/.config/advanced-rest-client` 以下に置かれます（`settings.json`、
`state.json`、`themes-esm/`、`workspace/`、`logs/`、および Chromium 自身のプロファイル）。
store に書き戻すものは何もないので、Anypoint Studio のような launcher は不要です。

## パッケージがしていること

### 同梱 Electron をそのまま使う

ソースは GitHub にあり中身は素の JavaScript なので、`buildNpmPackage` でビルドする、
あるいは少なくとも上流の `app.asar` を今の `pkgs.electron` で動かす、というのが自然な
発想です。どちらも通りません。

レンダラは `npm run bundle:ui` が約 90 個の `@advanced-rest-client/*` パッケージから
束ねるもので、2022 年当時と同じようには解決しません。そしてメインプロセスは
[`esm`](https://github.com/standard-things/esm)（2020 年に開発が止まった CommonJS/ESM
シム。V8 の内部にモンキーパッチを当てます）経由で読み込まれます。新しい Electron では
ARC 自身のコードに到達する前に、ロード中に落ちます:

```
App threw an error during load
TypeError: Function.prototype.apply was called on undefined
    at .../app.asar/node_modules/esm/esm.js:1:224377
    at Object.<anonymous> (.../app.asar/src/io/main.js:12:1)
```

つまり ARC は同梱の Electron 17 でしか起動しません。よって作業は、ビルド済み Chromium
に対するいつもの内容 — interpreter と RUNPATH を patch してラップする — になります。

### `.tar.gz` ではなく `.deb`

同じリリースで両方公開されています。electron-builder は hicolor のアイコン一式と
desktop エントリをディストリ向けパッケージにしか入れず、しかも同じツリーで `tar.gz`
のほうが 40 MB 大きいためです。

### `chrome-sandbox` は削除する

`chrome-sandbox` は setuid のサンドボックスヘルパで、store の中身は setuid にできません。
つまりこのコピーは、本来の役目を果たせません。

消しても観測できる変化はありません。setuid でないコピーをバイナリの隣に戻して確認しま
したが、ARC の起動も動作も同じです。そもそもヘルパに到達しないからで、Electron 17 は
既定でレンダラを `--no-sandbox` で起動します（ファイルの有無にかかわらず `pgrep -af` で
確認できます）。それでも削除しているのは、機能しない特権パス用バイナリを store に置いて
おきたくないためです。

### ANGLE の `libGL` は正しい RUNPATH に載せる必要がある

`autoPatchelfHook` が解決するのは `DT_NEEDED` で、Chromium が `dlopen` する分は見えません。
最初は `runtimeDependencies` を使いましたが、これは**未解決の `DT_NEEDED` を持つファイル**の
RUNPATH しか伸ばさないため、メインバイナリで止まりました。しかし `dlopen` は
**呼び出し側**オブジェクトの RUNPATH で解決されます。呼ぶのは `libEGL.so` で、その
RUNPATH は空のままでした:

```
ANGLE Display::initialize error 12289: Could not dlopen libGL.so.1
Exiting GPU process due to errors during initialization
```

クラッシュはしません。Chromium がソフトウェアレンダリングにフォールバックするので、
症状は「UI が重い」だけです。`appendRunpaths` はすべての ELF に追記するので解決します。
入れているのは、ANGLE 用の libglvnd と pciutils、Notification API 用の libnotify、
`safeStorage` 用の libsecret、ホットプラグ用の libudev、音声用の libpulseaudio です。

### `--skip-app-update` をラッパーに埋め込む

`ApplicationUpdater.start()` は electron-updater の `autoDownload` を既定のままにして
`setTimeout(() => this.check(), 5000)` を仕掛けます。つまり起動 5 秒後に毎回、自分の
インストール先へリリースを取得・インストールしようとします。store では不可能ですし、
`.deb` には `resources/app-update.yml` が入っていないので、静かに失敗すらせず UI に
アップデータのエラーを出します。このフラグを渡すと `autoDownload` と
`autoInstallOnAppQuit` を無効にしてタイマーを仕掛ける前に return する分岐に入ります
（そもそも 17.0.9 が最終版なので、見つかる更新はありません）。

## 既知の制限

- **Chromium 98 で固定、しかもレンダラはサンドボックス外**です。Electron 17 は 2022 年に
  EOL を迎え、上流も無くなったので、積み上がった CVE は永久にそのままです。さらに
  `WindowsManager.createBaseWindowOptions()` は `webPreferences.sandbox` を設定しておらず、
  Electron がこれを既定で `true` にしたのは 20 からなので、ARC のレンダラはすべて
  `--no-sandbox` で動きます。これは上流の選択であってパッケージング側の問題ではなく、
  アプリの動作を変えずに外から直すことはできません。任意の宛先に HTTP を投げるツールで
  あることを踏まえて扱ってください。
- **Wayland ネイティブでは動きません。** 他の Electron パッケージで Wayland に渡している
  `--ozone-platform-hint=auto` は Chromium 102 からで、98 では未知のスイッチです。ARC は
  XWayland で動きます。
- **起動のたびに 1 行のノイズが出ます:**
  ```
  xdg-mime: application argument missing
  ```
  `start.js` が `app.setAsDefaultProtocolClient('arc-file')` を呼びます。登録自体は成功して
  いて、`~/.config/mimeapps.list` に
  `x-scheme-handler/arc-file=advanced-rest-client.desktop` が入ります。失敗するのはその後の
  `xdg-settings` による読み戻し確認で、Plasma 環境では書き込んだ先とは別のソースを見るため
  「失敗した」と判断し、元のハンドラを復元しようとします。元のハンドラは存在しないので
  この呼び出しになります。
- x86-64 Linux のみです。

## ライセンス

この flake は MIT です（[LICENSE](./LICENSE) 参照）。どちらのアプリケーションもここでは
再配布しておらず、ビルド時に上流から取得します。Anypoint Studio は MuleSoft の
プロプライエタリソフトウェアなので `unfree` を設定しています。Advanced REST Client は
Apache-2.0 です。
