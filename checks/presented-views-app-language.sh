#!/usr/bin/env bash
# 扫描守卫：每个 sheet / popover 的内容、每个自建的 NSHostingView / NSHostingController，
# 都必须自己套一层 `.appLanguage()`。
#
# 由来（docs/bugfixes/2026-09-24-sheets-ignore-in-app-language.md）：应用内语言是在
# 两个场景的根上用 `.appLanguage()` 注入 `\.locale` 的，而 SwiftUI **不把 `\.locale`
# 带进 sheet 和 popover**（2026-09-24 macOS 26 探针实测：窗口里 zh-Hans，同一个窗口
# 弹出的 sheet 和 popover 里都是 en_US）。于是「系统英文、应用里选简体中文」的时候，
# 所有 sheet / popover 里的 `Text("…")` 一律显示英文，只有走 `L10n(…)` 的那几句是中文
# —— 导出面板改版时在中文界面里冒烟才看见。自建的宿主视图是新的根，同理。
#
# 长期约束见 docs/architecture/localization.md。
set -euo pipefail
cd "$(dirname "$0")/.."

# **不要用 `git ls-files`**：新写的文件常常还没 add，会被静默跳过。
FILES="$(find Sources/SrtFlow -name '*.swift' | sort)"

# perl 程序放进带引号的 heredoc，一个字都不经 shell 展开（shell 陷阱 5：
# /bin/bash 3.2 在 $( … ) 里会把单引号解析错位）。
read -r -d '' PROG <<'PERL' || true
use strict;
use warnings;

my ($fail, $count) = (0, 0);

# 从 $i 处的开括号起配对，返回对应闭括号的位置；配不上返回 undef。
sub closing {
    my ($s, $i, $open, $close) = @_;
    my $depth = 0;
    for (my $j = $i; $j < length($s); $j++) {
        my $c = substr($s, $j, 1);
        if ($c eq $open) { $depth++ }
        elsif ($c eq $close) { $depth--; return $j if $depth == 0 }
    }
    return undef;
}

sub line_of { my ($s, $pos) = @_; return 1 + (substr($s, 0, $pos) =~ tr/\n//); }

for my $file (@ARGV) {
    open(my $fh, '<', $file) or die "读不了 $file";
    my $src = do { local $/; <$fh> };
    close($fh);
    # 整行注释换成空行（行号不变）：说明文字里常写着 `.sheet(` 这样的字样。
    $src =~ s{^[ \t]*//[^\n]*}{}mg;

    # sheet / popover：内容是参数括号后面的尾随闭包（或括号里的 content: 闭包）。
    while ($src =~ /\.(sheet|popover)\(/g) {
        my ($kind, $open) = ($1, pos($src) - 1);
        my $args_end = closing($src, $open, '(', ')');
        if (!defined $args_end) {
            print STDERR "✗ $file:" . line_of($src, $open) . " .$kind( 的括号配不上 —— 认不出的写法直接红，别静默跳过\n";
            $fail = 1;
            next;
        }
        my $i = $args_end + 1;
        $i++ while $i < length($src) && substr($src, $i, 1) =~ /\s/;
        my $body;
        if (substr($src, $i, 1) eq '{') {
            my $end = closing($src, $i, '{', '}');
            $body = defined $end ? substr($src, $i, $end - $i + 1) : '';
        } else {
            $body = substr($src, $open, $args_end - $open + 1);
        }
        $count++;
        next if $body =~ /appLanguage\(\)/;
        print STDERR "✗ $file:" . line_of($src, $open) . " .$kind 的内容没套 .appLanguage()（sheet / popover 不继承应用内语言）\n";
        $fail = 1;
    }

    # 自建的宿主视图：rootView 那个参数里就得套上。
    while ($src =~ /NSHosting(?:View|Controller)\(/g) {
        my $open = pos($src) - 1;
        my $end = closing($src, $open, '(', ')');
        my $args = defined $end ? substr($src, $open, $end - $open + 1) : '';
        $count++;
        next if $args =~ /appLanguage\(\)/;
        print STDERR "✗ $file:" . line_of($src, $open) . " 自建的宿主视图没给 rootView 套 .appLanguage()（新的根不带应用内语言）\n";
        $fail = 1;
    }
}

if ($count == 0) {
    print STDERR "✗ 一个 sheet / popover / 宿主视图都没扫到 —— 守卫扫空了，检查路径和写法\n";
    exit 1;
}
print "✓ presented-views-app-language：$count 处 sheet / popover / 宿主视图都套了 .appLanguage()\n" unless $fail;
exit $fail;
PERL

# shellcheck disable=SC2086  # 文件名里没有空格（Sources/SrtFlow 的惯例），按词拆开传给 perl
perl -e "${PROG}" ${FILES}
