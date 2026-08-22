# 사람이 소유하는 파일 — 에이전트는 *.tf를 절대 수정하면 안 된다.
#
# 2-0-setup은 사람이 로컬에서 직접 apply하는 단 두 개의 루트 중 하나다
# (다른 하나는 1-00-setup). CI가 존재하는 데 필요한 것들(state 버킷, OIDC
# provider, GHA 롤)을 부트스트랩하는 루트라서, CI 안에서는 돌 수 없다.
#
# state는 로컬에 남으며 gitignore 대상이다(리포 .gitignore의 *.tfstate).
# 잃어버리지 말 것: 이 state 파일이 없으면 이미 부트스트랩된 계정에 대해
# terraform을 다시 돌릴 때 모든 리소스를 `terraform import`해야 한다.
#
# 나머지 모든 실습 루트(02~11)는 대신 비어 있는 s3 backend 블록을 담고 있다.
# CI가 init 시점에 bucket/key/region/use_lockfile을 주입하며, 그 대상은
# 바로 이 루트가 만드는 state 버킷이다.
terraform {
  backend "local" {}
}
