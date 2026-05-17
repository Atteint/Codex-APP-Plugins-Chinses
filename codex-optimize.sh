#!/bin/bash
# ============================================================
# Codex 优化一键脚本（幂等 — 已完成项自动跳过）
# 功能: 关闭完整性校验 + 插件解锁 + DNS加速 + 中文语言
# ============================================================

CODX_APP="/Applications/Codex.app"
ASAR="$CODX_APP/Contents/Resources/app.asar"

echo "========================================"
echo "  Codex 优化脚本"
echo "========================================"
echo ""

# === 0. 备份 ===
BACKUP_DIR="$HOME/.codex-backup-$(date +%Y%m%d)"
if [ ! -f "$BACKUP_DIR/app.asar.backup" ]; then
    echo "[0] 备份..."
    mkdir -p "$BACKUP_DIR"
    cp "$ASAR" "$BACKUP_DIR/app.asar.backup" 2>/dev/null || true
    cp "$CODX_APP/Contents/Info.plist" "$BACKUP_DIR/Info.plist.backup" 2>/dev/null || true
    echo "      备份到: $BACKUP_DIR"
else
    echo "[0] 备份已存在，跳过"
fi

# === 1. Fuse ===
FUSE_STATUS=$(npx --yes @electron/fuses read --app "$CODX_APP" 2>/dev/null | grep EnableEmbeddedAsarIntegrityValidation | awk '{print $NF}')
if [ "$FUSE_STATUS" != "Disabled" ]; then
    echo "[1] 关闭 EnableEmbeddedAsarIntegrityValidation..."
    npx --yes @electron/fuses write --app "$CODX_APP" EnableEmbeddedAsarIntegrityValidation=off 2>/dev/null
    echo "      ✅ 已禁用"
else
    echo "[1] Fuse 已是 Disabled，跳过"
fi

# === 2. asar 修补（auth 绕过 + 插件解锁）===
# Python 会自动检测是否已修补（找不到旧字符串则跳过）
echo "[2] 检查并修补 asar..."
python3 << 'PYEOF'
import hashlib, sys

asar_path = "/Applications/Codex.app/Contents/Resources/app.asar"

with open(asar_path, 'rb') as f:
    data = bytearray(f.read())

HEADER_SIZE = 382912
HEADER_END = 8 + HEADER_SIZE
FILE_OFFSET = HEADER_END + 139635090
FILE_SIZE = 3875

original = bytes(data[FILE_OFFSET:FILE_OFFSET + FILE_SIZE])

old_T = b'function T(){return{openAIAuth:null,authMethod:null,requiresAuth:!0,email:null,planAtLogin:null}}'
new_T = b'function T(){return{openAIAuth:`chatgpt`,authMethod:`chatgpt`,requiresAuth:!1,email:`proxy@local`,planAtLogin:`pro`}}'

old_E = b'function E(e){if(e==null)return null;switch(e.type){case`apiKey`:return`apikey`;case`amazonBedrock`:return null;case`chatgpt`:return`chatgpt`}}'
new_E = b'function E(e){if(e==null)return`chatgpt`;switch(e.type){default:return`chatgpt`}}'

old_v = b'v=m??{openAIAuth:null,authMethod:null,requiresAuth:!0,email:null,planAtLogin:null}'
new_v = b'v=m??{openAIAuth:`chatgpt`,authMethod:`chatgpt`,requiresAuth:!1,email:`proxy@local`,planAtLogin:`pro`}'

pos_T = original.find(old_T)
pos_E = original.find(old_E)
pos_v = original.find(old_v)

if pos_T < 0 or pos_E < 0 or pos_v < 0:
    print("      asar 已修补，跳过")
    sys.exit(0)

delta_T = len(new_T) - len(old_T)
delta_E = len(new_E) - len(old_E)
delta_v = len(new_v) - len(old_v)
padding = -(delta_T + delta_E + delta_v)

new_E_padded = new_E + b' ' * padding

patched = original[:pos_T] + new_T + original[pos_T+len(old_T):pos_E]
patched += new_E_padded + original[pos_E+len(old_E):pos_v]
patched += new_v + original[pos_v+len(old_v):]

assert len(patched) == FILE_SIZE, f"补丁大小不一致: {len(patched)} vs {FILE_SIZE}"

data[FILE_OFFSET:FILE_OFFSET + FILE_SIZE] = patched

new_hash = hashlib.sha256(bytes(patched)).hexdigest().encode()
old_hash = b'da07aaacd1aba5dd52024bc1b5ba1d29fb9b3c634d8e7cd396ced0d85b5886cf'
header = data[8:8+HEADER_SIZE]
if old_hash in header:
    data[8:8+HEADER_SIZE] = header.replace(old_hash, new_hash)

with open(asar_path, 'wb') as f:
    f.write(data)

print("      ✅ asar 修补完成")
PYEOF

# === 3. 包装脚本（DNS加速）===
if [ ! -f "$CODX_APP/Contents/MacOS/Codex.real" ]; then
    echo "[3] 创建 DNS 加速包装脚本..."
    cp "$CODX_APP/Contents/MacOS/Codex" "$CODX_APP/Contents/MacOS/Codex.real"

    cat > "$CODX_APP/Contents/MacOS/Codex" << 'SCRIPT'
#!/bin/bash
HOST_RULES="MAP api.openai.com 127.0.0.1, \
MAP auth.openai.com 127.0.0.1, \
MAP oauth.openai.com 127.0.0.1, \
MAP api.auth.openai.com 127.0.0.1, \
MAP ab.chatgpt.com 127.0.0.1, \
MAP cdn.openai.com 127.0.0.1, \
MAP chat.openai.com 127.0.0.1, \
MAP chatgpt.com 127.0.0.1, \
MAP persistent.oaistatic.com 127.0.0.1, \
MAP platform.openai.com 127.0.0.1"
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/Codex.real" "--host-resolver-rules=$HOST_RULES" "$@"
SCRIPT

    chmod +x "$CODX_APP/Contents/MacOS/Codex"
    echo "      ✅ 包装脚本已创建"
else
    echo "[3] 包装脚本已存在，跳过"
fi

# === 4. 中文语言 ===
CURRENT_LANG=$(defaults read com.openai.codex AppleLanguages 2>/dev/null | grep "zh-CN" | head -1)
if [ -z "$CURRENT_LANG" ]; then
    echo "[4] 设置中文语言..."
    defaults write com.openai.codex AppleLanguages '(zh-CN)'
    defaults write com.openai.codex AppleLocale zh_CN
    echo "      ✅ 中文语言已设置"
else
    echo "[4] 中文语言已设置，跳过"
fi

# === 5. 重新签名（总是执行）===
echo "[5] 重新签名..."
xattr -d com.apple.quarantine "$CODX_APP" 2>/dev/null || true
codesign --remove-signature "$CODX_APP" 2>/dev/null || true
codesign -f -s - --deep "$CODX_APP" 2>/dev/null
echo "      ✅ 签名完成"

echo ""
echo "========================================"
echo "  ✅ Codex 优化完成！"
echo "========================================"
echo ""
echo "首次启动时 macOS 会提示无法验证开发者，请："
echo "  系统设置 → 隐私与安全性 → 点击'仍要打开'"
echo ""
echo "之后重启 Codex 即可生效："
echo "  ✅ 插件功能可用"
echo "  ✅ OpenAI 域名仅对 Codex 禁用（不影响其他应用）"
echo "  ✅ 中文界面"
echo "  ✅ 启动更快"
echo ""
echo "恢复原始状态:"
echo "  cp $BACKUP_DIR/app.asar.backup $ASAR"
echo "  cp $BACKUP_DIR/Info.plist.backup $CODX_APP/Contents/Info.plist"