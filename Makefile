BINDIR=$(HOME)/bin
SCRIPTS_DIR=$(CURDIR)/shipyard/scripts/shared
export SCRIPTS_DIR

GOPROXY=https://proxy.golang.org
export GOPROXY

DAPPER_OUTPUT=$(CURDIR)/output
export DAPPER_OUTPUT

CLUSTERS_ARGS=--globalnet
DEPLOY_ARGS=--globalnet
SETTINGS=--settings $(CURDIR)/shipyard/.shipyard.e2e.yml

REPO=localhost:5000
IMAGE_VER=local
PRELOADS=lighthouse-agent lighthouse-coredns submariner-gateway submariner-globalnet submariner-route-agent submariner-networkplugin-syncer submariner-operator

HELM_VERSION=v3.4.1
YQ_VERSION=4.14.1
ARCH=amd64

all-images:	mod-replace mod-download build images preload-images

##@ Prepare

git-init:	## Initialise submodules
	git submodule update --init

prereqs:	## Download required utilities
	[ -x $(BINDIR)/yq ] || (curl -Lo $(BINDIR)/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" && chmod a+x $(BINDIR)/yq)
	[ -x $(BINDIR)/helm ] || (curl -L "https://get.helm.sh/helm-$(HELM_VERSION)-linux-$(ARCH).tar.gz" | tar xzf - && mv linux-$(ARCH)/helm $(BINDIR) && rm -rf linux-$(ARCH))

mod-replace:	## Update go.mod files with local replacements
	(cd admiral; go mod edit -replace=github.com/submariner-io/shipyard=../shipyard)
	(cd cloud-prepare; go mod edit -replace=github.com/submariner-io/admiral=../admiral)
	(cd lighthouse; go mod edit -replace=github.com/submariner-io/admiral=../admiral)
	(cd lighthouse; go mod edit -replace=github.com/submariner-io/shipyard=../shipyard)
	(cd submariner; go mod edit -replace=github.com/submariner-io/admiral=../admiral)
	(cd submariner; go mod edit -replace=github.com/submariner-io/shipyard=../shipyard)
	(cd submariner-operator; go mod edit -replace=github.com/submariner-io/admiral=../admiral)
	(cd submariner-operator; go mod edit -replace=github.com/submariner-io/shipyard=../shipyard)
	(cd submariner-operator; go mod edit -replace=github.com/submariner-io/cloud-prepare=../cloud-prepare)
	(cd submariner-operator; go mod edit -replace=github.com/submariner-io/lighthouse=../lighthouse)
	(cd submariner-operator; go mod edit -replace=github.com/submariner-io/submariner=../submariner)
	(cd submariner-operator; go mod edit -replace=github.com/submariner-io/submariner/pkg/apis=../submariner/pkg/apis)

mod-download:	## Download all module dependencies to go module cache
	(cd admiral; go mod download)
	(cd cloud-prepare; go mod download)
	(cd lighthouse; go mod download)
	(cd submariner; go mod download)
	(cd submariner-operator; go mod download)


##@ Build

build:	## Build all the binaries
build:	build-lighthouse build-submariner build-subctl build-operator

build-lighthouse:	## Build the lighthouse binaries
	(cd lighthouse; $(SCRIPTS_DIR)/compile.sh bin/lighthouse-agent pkg/agent/main.go)
	(cd lighthouse; $(SCRIPTS_DIR)/compile.sh bin/lighthouse-coredns pkg/coredns/main.go)

build-submariner:	## Build the submariner gateway binaries
	(cd submariner; $(SCRIPTS_DIR)/compile.sh bin/linux/amd64/submariner-gateway main.go)
	(cd submariner; $(SCRIPTS_DIR)/compile.sh bin/linux/amd64/submariner-globalnet pkg/globalnet/main.go)
	(cd submariner; $(SCRIPTS_DIR)/compile.sh bin/linux/amd64/submariner-route-agent pkg/routeagent_driver/main.go)
	(cd submariner; $(SCRIPTS_DIR)/compile.sh bin/linux/amd64/submariner-networkplugin-syncer pkg/networkplugin-syncer/main.go)

build-operator:		## Build the operator binaries
	(cd submariner-operator; $(SCRIPTS_DIR)/compile.sh bin/submariner-operator main.go)

build-subctl:	submariner-operator/bin/subctl	## Build the subctl binary

submariner-operator/bin/subctl:		Makefile.subctl
	mkdir -p submariner-operator/build
	(cd submariner-operator; $(MAKE) -f ../$< bin/subctl)

images:	## Build all the images
images:	image-lighthouse image-submariner image-operator

image-lighthouse:	## Build the lighthouse images
	(cd lighthouse; docker build -t $(REPO)/lighthouse-agent:$(IMAGE_VER) -f package/Dockerfile.lighthouse-agent .)
	(cd lighthouse; docker build -t $(REPO)/lighthouse-coredns:$(IMAGE_VER) -f package/Dockerfile.lighthouse-coredns .)

BUILD_ARGS=--build-arg TARGETPLATFORM=linux/amd64

image-submariner:	## Build the submariner gateway images
	(cd submariner; docker build -t $(REPO)/submariner-gateway:$(IMAGE_VER) -f package/Dockerfile.submariner-gateway $(BUILD_ARGS) .)
	(cd submariner; docker build -t $(REPO)/submariner-globalnet:$(IMAGE_VER) -f package/Dockerfile.submariner-globalnet $(BUILD_ARGS) .)
	(cd submariner; docker build -t $(REPO)/submariner-route-agent:$(IMAGE_VER) -f package/Dockerfile.submariner-route-agent $(BUILD_ARGS) .)
	(cd submariner; docker build -t $(REPO)/submariner-networkplugin-syncer:$(IMAGE_VER) -f package/Dockerfile.submariner-networkplugin-syncer $(BUILD_ARGS) .)

image-operator:		## Build the submariner operator image
	(cd submariner-operator; docker build -t $(REPO)/submariner-operator:$(IMAGE_VER) -f package/Dockerfile.submariner-operator .)

preload-images:		## Push images to development repository
	for repo in $(PRELOADS); do docker push $(REPO)/$$repo:$(IMAGE_VER); done

##@ Deployment

clusters:	## Create kind clusters that can be used for testing
	@mkdir -p $(DAPPER_OUTPUT)
	(cd submariner-operator; $(SCRIPTS_DIR)/clusters.sh $(CLUSTERS_ARGS) $(SETTINGS) )

deploy:	export DEV_VERSION=devel
deploy:	export CUTTING_EDGE=devel
deploy:		## Deploy submariner onto kind clusters
	./deploy.sh $(DEPLOY_ARGS) $(SETTINGS)

undeploy:	## Clean submariner deployment from clusters
	for k in output/kubeconfigs/*; do kubectl --kubeconfig $$k delete ns submariner-operator; kubectl --kubeconfig $$k delete ns submariner-k8s-broker; done

pod-status:	## Show status of pods in kind clusters
	for k in output/kubeconfigs/*; do kubectl --kubeconfig $$k get pod -A; done

##@ General

shell:
	$(SHELL)

clean:	## Clean up the built artifacts
	rm -f lighthouse/bin/lighthouse-agent
	rm -f lighthouse/bin/lighthouse-coredns
	rm -f submariner/bin/linux/amd64/submariner-gateway
	rm -f submariner/bin/linux/amd64/submariner-globalnet
	rm -f submariner/bin/linux/amd64/submariner-route-agent
	rm -f submariner/bin/linux/amd64/submariner-networkplugin-syncer
	rm -f submariner-operator/bin/submariner-operator
	rm -f submariner-operator/bin/subctl*

clean-clusters:	## Removes the running kind clusters
	(cd submariner-operator; $(SCRIPTS_DIR)/cleanup.sh)


help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: help
.DEFAULT_GOAL := help