# Ordo Linux — 开发入口
#
# 宪法要求「一个入口」。对**开发者**而言的入口就是这里：
# 所有验收都是一条 make 目标，不依赖某台机器的临时习惯。

SHELL := /bin/sh
ROOT  := $(CURDIR)

.DEFAULT_GOAL := help
.PHONY: help check test lint verify selfcheck doctor fmt install-plan clean

help: ## 列出可用目标
	@printf 'Ordo 开发目标：\n\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@printf '\n提交前请至少跑：make check\n'

check: lint test selfcheck ## 提交门禁：lint + 测试 + 自检
	@printf '\n✔ make check 全绿\n'

lint: ## 静态检查（语法 / shellcheck / 配置解析 / 声明层格式）
	@sh tests/lint.sh

test: ## 行为测试（防回归用例）
	@_out="$$(mktemp)"; sh tests/run-all.sh > "$$_out" 2>&1; _rc=$$?; \
	  tail -20 "$$_out"; rm -f "$$_out"; exit $$_rc
	# 注意：不能写成 `run-all | tail`——管道会让退出码被 tail 吞掉，
	# 门禁永远显示全绿（2026-11-22 实测发现并修复）。

verify: ## 检查仓库声明与本机实际状态的漂移
	@sh scripts/ordo-config verify

selfcheck: ## CLI 自检（usage × 分发 × 软链）
	@sh scripts/ordo-selfcheck

doctor: ## 全系统健康检查
	@sh scripts/doctor

install-plan: ## 显示安装器将执行的阶段（不执行）
	@sh scripts/sysup --dry-run 2>/dev/null || \
	  printf 'install.sh 阶段清单：\n' && \
	  grep -nE '^# ---- [0-9]' install.sh | sed 's/^/  /'

clean: ## 清理测试临时产物
	@rm -rf .test-tmp
