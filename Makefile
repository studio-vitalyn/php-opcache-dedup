# Everything runs in the "dev" container on the Docker host; the local machine
# only holds this repository.
#
#   make up                        build and start the container
#   make patches                   regenerate patches/*.patch from src/ + hooks
#   make test [SERIES=8.4]         dedup phpt tests (debug build)
#   make test-all                  dedup phpt tests on every series
#   make test-opcache SERIES=8.4   ext/opcache/tests, dedup off vs on
#   make test-full SERIES=8.4      Zend/tests + tests + ext/opcache/tests, off vs on
#   make bench [SERIES=8.4] [SITES=80] [IDENTICAL=80]
#   make shell

# host and directory: override them in local.mk (not versioned) or on the command line
-include local.mk
DOCKER_HOST_SSH ?= docker-host
REMOTE_DIR      ?= opcache-dedup
SERIES          ?= 8.4
SITES           ?= 80
IDENTICAL       ?= 80
MEMORY          ?= 8192
INTERNED        ?= 256
FLAVOR          ?=
GDB             ?= 0
PROTECT         ?= 0
MEMCHECK        ?= 0
ALL_SERIES      := $(shell grep -v '^\#' scripts/versions | awk '{print $$1}')

AUTHOR     := $(shell git var GIT_AUTHOR_IDENT | sed -E 's/ <.*//')
AUTHOR_MAIL:= $(shell git var GIT_AUTHOR_IDENT | sed -E 's/.*<(.*)>.*/\1/')
AUTHOR_ENV  = -e GIT_AUTHOR_NAME="$(AUTHOR)" -e GIT_AUTHOR_EMAIL=$(AUTHOR_MAIL)
SSH  = ssh $(DOCKER_HOST_SSH)
EXEC = $(SSH) 'cd $(REMOTE_DIR) && docker compose exec -T $(AUTHOR_ENV) dev'

.PHONY: sync up down shell patches test test-all test-opcache test-full bench

sync:
	rsync -a --delete --exclude .git ./ $(DOCKER_HOST_SSH):$(REMOTE_DIR)/

up: sync
	$(SSH) 'cd $(REMOTE_DIR) && docker compose up -d --build'

down:
	$(SSH) 'cd $(REMOTE_DIR) && docker compose down'

shell: sync
	$(SSH) -t 'cd $(REMOTE_DIR) && docker compose exec dev bash'

# Pristine trees live in the container's build volume
patches: sync
	$(EXEC) docker/patches.sh
	rsync -a $(DOCKER_HOST_SSH):$(REMOTE_DIR)/patches/ patches/

test: sync
	$(SSH) 'cd $(REMOTE_DIR) && docker compose exec -T -e FLAVOR=$(FLAVOR) -e MEMCHECK=$(MEMCHECK) dev docker/test.sh $(SERIES) dedup'

test-all: sync
	@rc=0; for s in $(ALL_SERIES); do echo "== $$s"; $(SSH) 'cd $(REMOTE_DIR) && docker compose exec -T -e FLAVOR=$(FLAVOR) -e MEMCHECK=$(MEMCHECK) dev docker/test.sh '$$s' dedup' || rc=1; done; exit $$rc

test-opcache: sync
	$(SSH) 'cd $(REMOTE_DIR) && docker compose exec -T -e FLAVOR=$(FLAVOR) -e MEMCHECK=$(MEMCHECK) dev docker/test.sh $(SERIES) opcache'

test-full: sync
	$(SSH) 'cd $(REMOTE_DIR) && docker compose exec -T -e FLAVOR=$(FLAVOR) -e MEMCHECK=$(MEMCHECK) dev docker/test.sh $(SERIES) full'

bench: sync
	$(SSH) 'cd $(REMOTE_DIR) && docker compose exec -T -e MEMORY=$(MEMORY) -e INTERNED=$(INTERNED) -e FLAVOR=$(FLAVOR) -e GDB=$(GDB) -e PROTECT=$(PROTECT) dev docker/bench/run.sh $(SERIES) $(SITES) $(IDENTICAL)'
