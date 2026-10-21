# Changelog

## [0.1.1](https://github.com/Eliitme/Cluvia/compare/v0.1.0...v0.1.1) (2026-10-21)


### Bug Fixes

* report a timed-out process as a timeout, not as its exit status ([0387aab](https://github.com/Eliitme/Cluvia/commit/0387aab8722e18e59ab03071807faaf54f783ff2))

## 0.1.0 (2026-10-20)


### Features

* add brand identity, app icon and accent color ([f92bf49](https://github.com/Eliitme/Cluvia/commit/f92bf49b82a51a4c64b0fbc9d1c11ad69700f2fc))
* add cluster catalog, resource browser and detail inspector ([ac26003](https://github.com/Eliitme/Cluvia/commit/ac260031906e48a422dc5c0517bb918c3056749e))
* add container shells and port forwarding over websockets ([4a249e7](https://github.com/Eliitme/Cluvia/commit/4a249e7e4b60a1fbaa042cfa8ca7ee43a1677508))
* add log streaming, YAML editing, resource actions and command palette ([a096d86](https://github.com/Eliitme/Cluvia/commit/a096d86802f4dd212974d0645c07f5a945fb55ea))
* chart pod, node and workload usage from prometheus ([b52ea5b](https://github.com/Eliitme/Cluvia/commit/b52ea5ba5bdd9eac0257959daa35e386d35602b9))
* clearer detail panel with titled actions, status badge and object shortcuts ([48101c2](https://github.com/Eliitme/Cluvia/commit/48101c27d34f8c19c29541d4e0c2797c993fb4c2))
* cluster badges, focused sidebar tree and per-row actions ([5d11696](https://github.com/Eliitme/Cluvia/commit/5d11696d505548d2d30e30ab979254f0413ce10a))
* color log lines by severity and tidy usage charts ([71ca3a9](https://github.com/Eliitme/Cluvia/commit/71ca3a9d122944aba04b3ff51491703307c36527))
* drain nodes and open node shells ([145171a](https://github.com/Eliitme/Cluvia/commit/145171a76acf55906486cbd64893bbed301997b8))
* **kubekit:** add discovery, dynamic client and watch cache ([55647fe](https://github.com/Eliitme/Cluvia/commit/55647fea5306ca5bbdf3b7808edc3aa38d4284b6))
* **kubekit:** add kubeconfig loading, credentials and cluster transport ([843c8b2](https://github.com/Eliitme/Cluvia/commit/843c8b2a534822bd2084387e599181dbae6525ce))
* **kubekit:** add YAML rendering, object counts and store restart ([3f6913f](https://github.com/Eliitme/Cluvia/commit/3f6913f99c12ab515b72f5800d2e2c915e2771ed))
* manage helm releases ([2dc62a2](https://github.com/Eliitme/Cluvia/commit/2dc62a2ae386238f07b58126232669bb250cba9c))
* manage kubeconfig contexts from a cluster sidebar ([164e2f0](https://github.com/Eliitme/Cluvia/commit/164e2f0a0732bc8411732d2dab77eaa55f431bb4))
* named namespace picker, informative status bar and clearer status cells ([106f364](https://github.com/Eliitme/Cluvia/commit/106f3647f3c0c153f8c4d8d0484d6d3928ab6e68))
* richer connect screen with sign-in method and auto-connect ([a398678](https://github.com/Eliitme/Cluvia/commit/a398678a6253ae173218effaa27bfc2a677e2022))
* search objects across kinds and stream logs of whole workloads ([666e473](https://github.com/Eliitme/Cluvia/commit/666e4731be206d173845d2b93372d4e1da0efc09))
* show live CPU and memory for pods and nodes ([9f5bf7a](https://github.com/Eliitme/Cluvia/commit/9f5bf7a883b19e2d2663f5074177a9422743501e))
* show release notes and what's new from the bundled changelog ([92f3f73](https://github.com/Eliitme/Cluvia/commit/92f3f73ff04f0f36624c7da3f9a398518de4bca7))


### Bug Fixes

* drop placeholder sidebar rows that stayed drawn after connecting ([3cab4cf](https://github.com/Eliitme/Cluvia/commit/3cab4cf1237f59fbf8053ddf1f7dc287cc938790))
* flatten the sidebar tree and make the detail panel resize reliably ([ba7d20a](https://github.com/Eliitme/Cluvia/commit/ba7d20ae25a22ceae2bc0892aed85ff10bf36cb4))
* give the inspector its own toolbar section and an opaque sidebar footer ([c7c96ec](https://github.com/Eliitme/Cluvia/commit/c7c96ec9515f565a2cd00d3f25393d0a41940ffb))
* harden quit cleanup, drain completion, search caching and node shells ([878e8c8](https://github.com/Eliitme/Cluvia/commit/878e8c8ca6450f4118481ef957e8fdd12c1db19e))
* hold back height-only resizes while the shell is at its prompt ([dc43a03](https://github.com/Eliitme/Cluvia/commit/dc43a03478fe3d652b88c146f3de0968c26830ef))
* keep detail header at the top when the tab is empty ([93f4801](https://github.com/Eliitme/Cluvia/commit/93f48019ade090a1367c5087e14d42abc6079501))
* keep the browser in place when toggling the bottom panel and send terminal size once ([1b4224e](https://github.com/Eliitme/Cluvia/commit/1b4224e59d3de46a55163417d0f14e59618592a2))
* live sidebar counts, red delete confirmation, empty remote port and sparse chart axes ([e8b6d88](https://github.com/Eliitme/Cluvia/commit/e8b6d88d6676f2b3e1beeaf336d6620a14cc67b3))
* redraw a cluster's sidebar row when it disconnects ([6c287e9](https://github.com/Eliitme/Cluvia/commit/6c287e9ce2ff95f2946816e02ad622c0e6bc6716))
* safer object commands, one-time auto-connect, precise log and status coloring ([3e458e0](https://github.com/Eliitme/Cluvia/commit/3e458e022df5d87e09f28b82438fde1807c4d517))
* show resource details in a split below the toolbar ([c90f90c](https://github.com/Eliitme/Cluvia/commit/c90f90c99f2f41fc7e522fd86b91412a660b7a20))
* show the detail panel only for a selected object ([3243c33](https://github.com/Eliitme/Cluvia/commit/3243c33a49ff5ce1807a7b1fccf86cadf4cbf3ec))
* size the shell's terminal before it starts and give the bottom panel a remembered height ([8783c9f](https://github.com/Eliitme/Cluvia/commit/8783c9fc4e903eddfe67644994053eca89583fb4))

## Changelog

All notable changes to Cluvia are documented here. Entries are generated from
[Conventional Commits](https://www.conventionalcommits.org/) by release-please when a release is prepared.
