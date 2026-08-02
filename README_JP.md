# mulesoft.nix

[English](./README.md) | 日本語

MuleSoft のツールを NixOS 向けにパッケージする Nix flake です。現在含まれるのは
**Anypoint Studio**（MuleSoft の Eclipse ベース IDE）1 つです。

配布物は約 2.2 GB の Linux 向け tarball で、Temurin JDK と Equo Chromium (CEF) を
同梱したビルド済みの Eclipse 製品です。コンパイルするものは何もなく、作業の中身は
その一式を nixpkgs のライブラリで動かすことと、**読み取り専用ディレクトリからの
起動を拒否するアプリケーションを `/nix/store` から動かすこと**です。

## 使い方

Anypoint Studio はプロプライエタリなので、利用側で
`nixpkgs.config.allowUnfree = true;` が必要です。

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
environment.systemPackages = [
  inputs.mulesoft.packages.${pkgs.system}.anypoint-studio
];
```

overlay 経由で `pkgs.anypoint-studio` として使う場合:

```nix
nixpkgs.overlays = [ inputs.mulesoft.overlays.default ];
```

### インストールせずに試す

```console
$ nix run github:solitarywalker/mulesoft.nix
```

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

## ライセンス

この flake は MIT です（[LICENSE](./LICENSE) 参照）。Anypoint Studio 自体は MuleSoft の
プロプライエタリソフトウェアで、ここでは再配布していません。導出はビルド時に MuleSoft
から取得し、それに応じて `unfree` を設定しています。
