# 툴/CI 주입 — 편집 금지. CI가 init 시 key=states/<디렉터리>.tfstate 를 주입한다.
terraform {
  backend "s3" {}
}
