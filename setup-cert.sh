#!/bin/bash
# 创建一张自签名的「代码签名」证书并导入登录钥匙串。
# 作用：用它给 NotifBark 签名后，TCC（完全磁盘访问）按证书身份认 app，
#       而不是按文件哈希——以后重新编译不会让授权失效，无需反复授权。
# 只需运行一次。
set -e

CN="NotifBark Self Signed"
P12_PASS="notifbark"
KC="$HOME/Library/Keychains/login.keychain-db"
OSSL=/usr/bin/openssl   # 必须用系统 LibreSSL：它生成的 p12 与 Apple Security 兼容
OUT="$(cd "$(dirname "$0")" && pwd)/cert"

if security find-identity -p codesigning | grep -q "$CN"; then
  echo "✓ 签名身份「$CN」已存在，跳过。"
  exit 0
fi

mkdir -p "$OUT"
cd "$OUT"

cat > cfg.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# 生成 key + 自签名证书（带 codeSigning 用途）
"$OSSL" req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config cfg.cnf >/dev/null 2>&1
# 打包成 p12（LibreSSL 默认算法即 Apple 兼容）
"$OSSL" pkcs12 -export -inkey key.pem -in cert.pem -out NotifBark.p12 -passout "pass:$P12_PASS" -name "$CN" >/dev/null 2>&1
# 导入登录钥匙串，并允许 codesign 使用该私钥（-T 避免签名时弹窗）
security import NotifBark.p12 -k "$KC" -P "$P12_PASS" -T /usr/bin/codesign -A >/dev/null 2>&1

echo "✓ 已创建并导入签名身份「$CN」。"
echo "  证书私钥在 $OUT （已被 .gitignore 忽略，请勿提交/外传）。"
echo "  注意：该证书不受信任（CSSMERR_TP_NOT_TRUSTED）属正常——不影响本地签名与 TCC。"
