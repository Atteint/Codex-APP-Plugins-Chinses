#!/bin/bash
# ============================================================
# Codex Optimization V3 — Complete Permanent Injection
# ============================================================
# 一次性注入，持久生效。只在以下情况需要重新运行：
#   - 新安装 codex.app
#   - codex.app 更新后
# 正常使用无需任何 wrapper 脚本。
# ============================================================
#
# 四个层面的修改：
#   1. Electron Fuses      → 禁用 asar 完整性验证
#   2. asar patch (robust)  → 绕过 OpenAI 认证检查（插件解锁）
#   3. /etc/hosts           → DNS 级别拦截所有 OpenAI/ChatGPT 域名
#   4. 重新签名             → macOS 可正常启动
#
# 备份位置：~/.codex-backup-YYYYMMDD/
# 恢复方法：
#   cp ~/.codex-backup-YYYYMMDD/*.backup ...
#   并移除 /etc/hosts 中的 # === Codex-Block === 段
# ============================================================

CODX_APP="/Applications/Codex.app"
ASAR="$CODX_APP/Contents/Resources/app.asar"
HOSTS="/etc/hosts"
HOSTS_MARKER_START="# === Codex-Block: OpenAI/ChatGPT DNS block ==="
HOSTS_MARKER_END="# === End Codex-Block ==="

echo "========================================"
echo "  Codex Optimization V3"
echo "  完整注入 — 一次运行，持久生效"
echo "========================================"
echo ""

# ============================================================
# 0. 备份
# ============================================================
BACKUP_DIR="$HOME/.codex-backup-$(date +%Y%m%d)"
if [ ! -f "$BACKUP_DIR/app.asar.backup" ]; then
    echo "[0] 备份原始文件..."
    mkdir -p "$BACKUP_DIR"
    cp "$ASAR" "$BACKUP_DIR/app.asar.backup" 2>/dev/null || true
    cp "$CODX_APP/Contents/Info.plist" "$BACKUP_DIR/Info.plist.backup" 2>/dev/null || true
    echo "      备份至: $BACKUP_DIR"
else
    echo "[0] 备份已存在，跳过"
fi

# ============================================================
# 1. Electron Fuses — 禁用 asar 完整性验证
# ============================================================
echo "[1] 检查 Electron Fuses..."
FUSE_STATUS=$(npx --yes @electron/fuses read --app "$CODX_APP" 2>/dev/null | grep EnableEmbeddedAsarIntegrityValidation | awk '{print $NF}')
if [ "$FUSE_STATUS" != "Disabled" ]; then
    echo "      正在禁用 EnableEmbeddedAsarIntegrityValidation..."
    npx --yes @electron/fuses write --app "$CODX_APP" EnableEmbeddedAsarIntegrityValidation=off 2>/dev/null
    echo "      完成: IntegrityValidation -> Disabled"
else
    echo "      已禁用，跳过"
fi

# ============================================================
# 2. asar patch — 认证绕过，解锁本地功能
#   使用全局字符串搜索（不依赖固定偏移量），更新后更鲁棒
# ============================================================
echo "[2] 检查并注入 asar patch..."
python3 << 'PYEOF'
import hashlib, sys, re

asar_path = "/Applications/Codex.app/Contents/Resources/app.asar"

with open(asar_path, 'rb') as f:
    data = bytearray(f.read())

# --- 目标字符串（原始代码，用于搜索）---
# 注：Python 3.12+ 中 \! 被识别为无效转义，
# 使用 \x21 表示字面感叹号 !；\x3f 表示 ?
old_T = b'function T(){return{openAIAuth:null,authMethod:null,requiresAuth:\x210,email:null,planAtLogin:null}}'
old_E = b'function E(e){if(e==null)return null;switch(e.type){case`apiKey`:return`apikey`;case`amazonBedrock`:return null;case`chatgpt`:return`chatgpt`}}'
old_v = b'v=m\x3f\x3f{openAIAuth:null,authMethod:null,requiresAuth:\x210,email:null,planAtLogin:null}'

# --- 替换字符串（patch 后的代码）---
new_T = b'function T(){return{openAIAuth:`chatgpt`,authMethod:`chatgpt`,requiresAuth:\x211,email:`proxy@local`,planAtLogin:`pro`}}'
new_E = b'function E(e){if(e==null)return`chatgpt`;switch(e.type){default:return`chatgpt`}}'
new_v = b'v=m\x3f\x3f{openAIAuth:`chatgpt`,authMethod:`chatgpt`,requiresAuth:\x211,email:`proxy@local`,planAtLogin:`pro`}'

# 全局搜索原始字符串
pos_T = data.find(old_T)
pos_E = data.find(old_E)
pos_v = data.find(old_v)

# 如果都找不到，检查是否已 patch
if pos_T < 0 and pos_E < 0 and pos_v < 0:
    if data.find(b'proxy@local') >= 0:
        print("      asar 已注入，跳过")
    else:
        print("      ⚠ 原始字符串未找到，版本可能不兼容")
        print("      跳过 asar patch（其他步骤照常进行）")
    sys.exit(0)

# 部分已 patch 的处理
unpatched = []
if pos_T < 0: unpatched.append("T")
if pos_E < 0: unpatched.append("E")
if pos_v < 0: unpatched.append("v")

if unpatched:
    print(f"      部分已 patch（{','.join(unpatched)} 仍需注入）")
    # 已 patch 的用新字符串位置
    if pos_T < 0:
        pos_T = data.find(new_T)
    if pos_E < 0:
        pos_E = data.find(new_E)
    if pos_v < 0:
        pos_v = data.find(new_v)

if pos_T < 0 or pos_E < 0 or pos_v < 0:
    print("      ⚠ 无法定位所有目标字符串，跳过 asar patch")
    sys.exit(0)

# 计算包含三个目标的最小窗口
min_pos = min(pos_T, pos_E, pos_v)
max_pos = max(pos_T, pos_E, pos_v) + len(old_v)
window_size = max_pos - min_pos

window = bytearray(data[min_pos:min_pos + window_size])

# 窗口内偏移
w_T = pos_T - min_pos
w_E = pos_E - min_pos
w_v = pos_v - min_pos

# 长度变化计算，用 padding 保持窗口总大小不变
delta_T = len(new_T) - len(old_T)
delta_E = len(new_E) - len(old_E)
delta_v = len(new_v) - len(old_v)
padding = -(delta_T + delta_E + delta_v)

if padding < 0:
    print(f"      ⚠ 替换后总长度超出 {abs(padding)} 字节，跳过")
    sys.exit(1)

new_E_padded = new_E + b' ' * padding

# 窗口内替换
patched = window[:w_T] + new_T + window[w_T+len(old_T):w_E]
patched += new_E_padded + window[w_E+len(old_E):w_v]
patched += new_v + window[w_v+len(old_v):]

assert len(patched) == window_size, \
    f"Patch size mismatch: {len(patched)} vs {window_size}"

# 写回
data[min_pos:min_pos + window_size] = patched

# 更新 asar 完整性哈希（fuse 已关，做不做都行，顺手）
HEADER_SIZE = int.from_bytes(data[4:8], 'little')
header_str = bytes(data[8:8+HEADER_SIZE]).decode('latin-1')
new_hash = hashlib.sha256(bytes(patched)).hexdigest()
old_hashes = re.findall(r'[0-9a-f]{64}', header_str)
if old_hashes:
    data[8:8+HEADER_SIZE] = bytearray(
        bytes(data[8:8+HEADER_SIZE]).replace(
            old_hashes[-1].encode(), new_hash.encode(), 1
        )
    )

with open(asar_path, 'wb') as f:
    f.write(data)

print("      asar 注入完成")
PYEOF

# ============================================================
# 3. /etc/hosts — 永久 DNS 拦截
#    注：/etc/hosts 不支持 *. 通配符，每个域名单独列出
# ============================================================
echo "[3] 配置 DNS 拦截（/etc/hosts）..."

HOSTS_ENTRIES=(
    "api.openai.com"
    "auth.openai.com"
    "oauth.openai.com"
    "api.auth.openai.com"
    "ab.chatgpt.com"
    "cdn.openai.com"
    "chat.openai.com"
    "chatgpt.com"
    "www.chatgpt.com"
    "chatgpt-staging.com"
    "persistent.oaistatic.com"
    "platform.openai.com"
    "developers.openai.com"
    "help.openai.com"
    "web-sandbox.oaiusercontent.com"
)

if grep -q "$HOSTS_MARKER_START" "$HOSTS" 2>/dev/null; then
    echo "      DNS 拦截已配置，跳过"
else
    echo "      需要 sudo 权限来修改 /etc/hosts..."
    echo ""

    # 构建 hosts 配置
    HOSTS_CONTENT=""
    HOSTS_CONTENT+="$HOSTS_MARKER_START\n"
    HOSTS_CONTENT+="# 由 codex-optimize-V3.sh 自动生成\n"
    HOSTS_CONTENT+="# 移除本段即可恢复网络连接\n"
    for domain in "${HOSTS_ENTRIES[@]}"; do
        HOSTS_CONTENT+="127.0.0.1 $domain\n"
        HOSTS_CONTENT+="::1 $domain\n"
    done
    HOSTS_CONTENT+="$HOSTS_MARKER_END"

    echo -e "$HOSTS_CONTENT" | sudo tee -a "$HOSTS" > /dev/null

    if [ $? -eq 0 ]; then
        echo "      [OK] DNS 拦截已写入 /etc/hosts (${#HOSTS_ENTRIES[@]} 个域名)"
        dscacheutil -flushcache 2>/dev/null || true
        killall -HUP mDNSResponder 2>/dev/null || true
        echo "      DNS 缓存已刷新"
    else
        echo "      [!!] /etc/hosts 写入失败，请手动添加（见脚本注释）"
    fi
fi

# ============================================================
# 4. 清理
# ============================================================
echo "[4] 清理..."
xattr -d com.apple.quarantine "$CODX_APP" 2>/dev/null || true

# 检查并提醒移除旧的 DNS wrapper 脚本关联
if [ -f "/Users/ivanyip/Documents/Codex/Codex_mac_intel_plugin/Codex-DNS-wrapper-v2.sh" ]; then
    echo "      检测到旧 wrapper 脚本 Codex-DNS-wrapper-v2.sh"
    echo "      现在可由本脚本完全替代，不再需要执行它"
fi

# ============================================================
# 5. 重新签名
# ============================================================
echo "[5] 重新签名应用..."
codesign --remove-signature "$CODX_APP" 2>/dev/null || true
codesign -f -s - --deep "$CODX_APP" 2>/dev/null
echo "      签名完成"

echo ""
echo "========================================"
echo "  [OK] Codex 完整注入完成！"
echo "========================================"
echo ""
echo "  现在可直接双击打开 Codex.app"
echo "  不再需要任何 wrapper 脚本"
echo ""
echo "  首次启动可能提示'无法验证开发者'："
echo "    系统设置 -> 隐私与安全性 -> 仍要打开"
echo ""
echo "  恢复原始状态："
echo "    1. 删除 /etc/hosts 中的 Codex-Block 段"
echo "    2. 还原备份："
echo "       cp \$BACKUP_DIR/app.asar.backup \$ASAR"
echo "       cp \$BACKUP_DIR/Info.plist.backup \$CODX_APP/Contents/Info.plist"
echo "    3. 重新签名：codesign -f -s - --deep \$CODX_APP"
echo ""
echo "  更新 codex.app 后需重新运行本脚本"
echo ""