# AWS credential sidecar.
# AWS CLI v2 の公式イメージ (Amazon Linux 2023) には /usr/bin/python3 が同梱されているので、
# 追加インストールなしで標準ライブラリだけの HTTP サーバを動かせる。
FROM public.ecr.aws/aws-cli/aws-cli:2.36.34

COPY server.py /server.py

# ホストの ~/.aws/config と ~/.aws/login/cache は compose が /root/.aws 配下に read-only で mount する。
# CLI が書き込む一時キャッシュ (~/.aws/cli/cache 等) はコンテナの writable layer に落ちる。
ENTRYPOINT ["python3", "/server.py"]
