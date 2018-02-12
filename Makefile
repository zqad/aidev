# vim:noet:ts=8:sw=8

include Makefile.options

# Check for acbuild
acbuild_check := $(shell command -v $(ACBUILD) 2> /dev/null)
ifndef acbuild_check
    $(error "Unable to find acbuild, supply a path using the ACBUILD environment variable")
endif

root_check := $(shell id -u)
ifneq ($(root_check),0)
    $(error "Run make as root")
endif

# .aci creation macros
define tmpdir
.$@.tmpdir
endef
define acbuild_prepare
	# Clean and create build dir
	rm -rf $(tmpdir)
	mkdir $(tmpdir)

	# Start and set name
	$(ACBUILD$@) begin ./$<
	$(ACBUILD$@) set-name $(@:.aci=)
endef
define acbuild_finalize_cleanup
	# Write file to build directory
	$(ACBUILD$@) write $(tmpdir)/$@

	# Move into place when successful
	mv -f $(tmpdir)/$@ .
	rm -rf $(tmpdir)
endef
define gen_acbuild
$(eval ACBUILD$(1).aci=$(ACBUILD) --work-path=.$(1).aci.tmpdir)
endef

# Generate default target
TARGET_IMAGE_BASES := tensorflow caffe2-py2 caffe2-py3
ifeq ($(GPU),true)
GPU_NOGPU:=gpu
else
GPU_NOGPU:=nogpu
endif
TARGET_IMAGES := $(foreach i,$(TARGET_IMAGE_BASES),$(i)-$(GPU_NOGPU).aci)
ALL_TARGET_IMAGES := $(foreach i,$(TARGET_IMAGE_BASES),$(i)-gpu.aci $(i)-nogpu.aci)

.PHONY: default all cudnn cuda tensorflow caffe2 clean
default: $(TARGET_IMAGES)

all: $(ALL_TARGET_IMAGES)

cudnn: cudnn.aci

cuda: cuda.aci

tensorflow: tensorflow-$(GPU_NOGPU).aci

caffe2-py2: caffe2-py2-$(GPU_NOGPU).aci

caffe2-py3: caffe2-py3-$(GPU_NOGPU).aci

clean:
	rm -f *.aci base.tar
	rm -rf .*.tmpdir
	rm -f .*.tmp

# Convert excludes-list to comma-separated list
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
COMMA := ,
_EXCLUDES := $(subst $(SPACE),$(COMMA),$(foreach e,$(EXCLUDES),$(e)))

######
### Base images
base.tar: $(EXCLUDES_FILE)
	rm -rf .$@.tmpdir .$@.tmp
	debootstrap --exclude=$(_EXCLUDES) $(SUITE) .$@.tmpdir $(REPO_URL)
	tar -C .$@.tmpdir -cf .$@.tmp .
	mv -f .$@.tmp $@
	rm -rf .$@.tmpdir

$(call gen_acbuild,base)
base.aci: base.tar files/base/init.sh files/base/sources.list.$(SUITE)
	$(acbuild_prepare)

	# Passwordless sudo for group cwheel
	$(ACBUILD$@) run -- groupadd cwheel
	$(ACBUILD$@) run -- sh -c "echo '%cwheel ALL = NOPASSWD: ALL' > /etc/sudoers.d/cwheel"

	# Fix startup things
	$(ACBUILD$@) copy-to-dir files/base/init.sh /
	$(ACBUILD$@) run -- chmod 755 /init.sh
	$(ACBUILD$@) run -- mkdir /init.d
	$(ACBUILD$@) set-exec /init.sh

	# Add sources.list
	$(ACBUILD$@) copy files/base/sources.list.$(SUITE) /etc/apt/sources.list
	$(ACBUILD$@) run -- apt update

	# Update packages
	$(ACBUILD$@) run -- apt dist-upgrade -y
	$(ACBUILD$@) run -- apt clean

	$(acbuild_finalize_cleanup)

$(call gen_acbuild,xbase)
xbase.aci: base.aci
	$(acbuild_prepare)

	$(ACBUILD$@) run -- apt install -y --no-install-recommends xauth x11-xserver-utils xterm rxvt-unicode-256color fonts-inconsolata
	$(ACBUILD$@) run -- apt clean

	$(acbuild_finalize_cleanup)

$(call gen_acbuild,build-xbase)
build-xbase.aci: xbase.aci
	$(acbuild_prepare)

	$(ACBUILD$@) run -- apt install -y screen sudo git python3 python3-pip strace vim-nox build-essential cmake
	$(ACBUILD$@) run -- apt clean

	$(acbuild_finalize_cleanup)

######
### GPU vendor-specific images
$(call gen_acbuild,cuda)
cuda.aci: build-xbase.aci
	$(acbuild_prepare)
	# Download CUDA and verify the checksum
	wget -O $(tmpdir)/cuda.deb $(CUDA_DEB_URL)
	test "$(CUDA_DEB_SHA256)" = "$$(sha256sum .$@.tmpdir/cuda.deb | cut -d' ' -f1)"
	wget -O $(tmpdir)/cuda.key $(CUDA_KEY_URL)
	test "$(CUDA_KEY_SHA256)" = "$$(sha256sum .$@.tmpdir/cuda.key | cut -d' ' -f1)"

	# Install the cuda repo
	$(ACBUILD$@) copy-to-dir $(tmpdir)/cuda.deb /
	$(ACBUILD$@) copy-to-dir $(tmpdir)/cuda.key /
	$(ACBUILD$@) run -- dpkg -i /cuda.deb
	$(ACBUILD$@) run -- apt-key add /cuda.key
	$(ACBUILD$@) run -- rm -f /cuda.deb /cuda.key

	# Install cuda itself
	$(ACBUILD$@) run -- apt update
	$(ACBUILD$@) run -- env DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends cuda

	$(ACBUILD$@) run -- apt clean

	# Make sure users can access the nvidia device
	$(ACBUILD$@) run -- groupadd aidev
	$(ACBUILD$@) copy files/cuda-gpu/init-aidev /init.d/00-aidev
	$(ACBUILD$@) run -- chmod 755 /init.d/00-aidev

	$(acbuild_finalize_cleanup)

$(call gen_acbuild,cudnn)
cudnn.aci: cuda.aci $(LIBCUDNN_DEB) $(LIBCUDNN_DEV_DEB)
	# Check that the required downloads are named and exists
	test -n "$(LIBCUDNN_DEB)" -a -e "$(LIBCUDNN_DEB)"
	test -n "$(LIBCUDNN_DEV_DEB)" -a -e "$(LIBCUDNN_DEV_DEB)"

	$(acbuild_prepare)

	$(ACBUILD$@) copy $(LIBCUDNN_DEB) /libcudnn.deb
	$(ACBUILD$@) copy $(LIBCUDNN_DEV_DEB) /libcudnn-dev.deb
	$(ACBUILD$@) run -- apt install -y --no-install-recommends /libcudnn.deb /libcudnn-dev.deb

	$(acbuild_finalize_cleanup)

######
### Framework images
ifeq ($(TF_NEED_MPI),1)
_TF_MPI_PACKAGES := openmpi-bin libopenmpi-dev
else
_TF_MPI_PACKAGES :=
endif
define tensorflow_recipe
	$(acbuild_prepare)

	# Relink python to use python3
	$(ACBUILD$@) run -- ln -sf python3 /usr/bin/python

	# Install deps according to https://www.tensorflow.org/install/install_sources
	# including jemalloc and nasm
	$(ACBUILD$@) run -- apt install -y python3-pip python3-numpy \
		python3-dev python3-wheel libjemalloc-dev $(_TF_MPI_PACKAGES)
	# Install bazel
	$(ACBUILD$@) copy-to-dir files/tensorflow//bazel.list /etc/apt/sources.list.d/
	wget -O$(tmpdir)/bazel-release.pub.gpg https://bazel.build/bazel-release.pub.gpg
	$(ACBUILD$@) copy-to-dir $(tmpdir)/bazel-release.pub.gpg /
	$(ACBUILD$@) run -- apt-key add /bazel-release.pub.gpg
	$(ACBUILD$@) run -- rm -f /bazel-release.pub.gpg
	$(ACBUILD$@) run -- apt update
	$(ACBUILD$@) run -- apt install -y bazel openjdk-9-jre- openjdk-9-jre-headless-

	# Refresh the java cacerts
	$(ACBUILD$@) run -- update-ca-certificates

	# Fetch and build
	$(ACBUILD$@) run -- git clone https://github.com/tensorflow/tensorflow /tensorflow
	$(ACBUILD$@) run -- sh -c 'cd /tensorflow && git checkout $(TF_VERSION_HASH)'
	$(ACBUILD$@) run -- sh -c 'test -z "$(1)" -o -e \
		/usr/local/cuda-$(TF_CUDA_VERSION)/targets/x86_64-linux/lib64 || \
		ln -s lib /usr/local/cuda-$(TF_CUDA_VERSION)/targets/x86_64-linux/lib64'
	$(ACBUILD$@) run -- sh -c ' \
		export PYTHON_BIN_PATH=/usr/bin/python ;\
		export TF_NEED_CUDA=$(if $(1),1,0) ;\
		export TF_NEED_JEMALLOC=1 ;\
		export USE_DEFAULT_PYTHON_LIB_PATH=1 ;\
		export CUDA_TOOLKIT_PATH=/usr/local/cuda-9.1/ ;\
		export CUDNN_INSTALL_PATH=/usr/lib/x86_64-linux-gnu ;\
		export TF_CUDA_CLANG=0 ;\
		export GCC_HOST_COMPILER_PATH=/usr/bin/gcc ;\
		export TF_CUDA_COMPUTE_CAPABILITIES=$(TF_CUDA_COMPUTE_CAPABILITIES) ;\
		export TF_CUDA_VERSION=$(TF_CUDA_VERSION) ;\
		export TF_CUDNN_VERSION=$(TF_CUDNN_VERSION) ;\
		export CC_OPT_FLAGS="$(TF_CC_OPT_FLAGS)" ;\
		export TF_NEED_GCP=$(TF_NEED_GCP) ;\
		export TF_NEED_HDFS=$(TF_NEED_HDFS) ;\
		export TF_NEED_S3=$(TF_NEED_S3) ;\
		export TF_ENABLE_XLA=$(TF_NEED_GDR) ;\
		export TF_NEED_GDR=$(TF_NEED_GDR) ;\
		export TF_NEED_VERBS=$(TF_NEED_VERBS) ;\
		export TF_NEED_OPENCL_SYCL=$(TF_NEED_OPENCL_SYCL) ;\
		export TF_NEED_MPI=$(TF_NEED_MPI) ;\
		export MPI_HOME=/usr/lib/openmpi ;\
		export TF_SET_ANDROID_WORKSPACE=$(TF_SET_ANDROID_WORKSPACE) ;\
		export TF_NEED_KAFKA=$(TF_NEED_KAFKA) ;\
		export TF_NEED_TENSORRT=$(TF_NEED_TENSORRT) ;\
		cd /tensorflow && ./configure --help'

	# Build and install
	$(ACBUILD$@) run -- sh -c 'cd /tensorflow && \
		bazel build --config=opt $(if $(1),--config=cuda,) \
		//tensorflow/tools/pip_package:build_pip_package'
	$(ACBUILD$@) run -- sh -c 'cd /tensorflow && \
		bazel-bin/tensorflow/tools/pip_package/build_pip_package /tensorflow_install'
	$(ACBUILD$@) run -- sh -c 'pip3 install \
		/tensorflow_install/tensorflow-*.whl'

	# Expose ports
	$(ACBUILD$@) port add tensorflow-http tcp 80
	$(ACBUILD$@) port add tensorboard-http tcp 6006

	# Clean up
	$(ACBUILD$@) run -- rm -rf /tensorflow /tensorflow_install
	$(ACBUILD$@) run -- apt purge -y bazel
	$(ACBUILD$@) run -- apt autoremove -y
	$(acbuild_finalize_cleanup)
endef
$(call gen_acbuild,tensorflow-nogpu)
tensorflow-nogpu.aci: build-xbase.aci
	$(call tensorflow_recipe,)

$(call gen_acbuild,tensorflow-gpu)
tensorflow-gpu.aci: cudnn.aci
	$(call tensorflow_recipe,gpu)

CAFFE2_PY2_PACKAGES = python-dev python-pip python-setuptools python-wheel
CAFFE2_PY3_PACKAGES = python3-dev python3-pip python3-setuptools python3-wheel
define caffe2_recipe
	$(acbuild_prepare)

	# Install for python3
	$(ACBUILD$@) run -- apt install -y --no-install-recommends \
		build-essential cmake git libgoogle-glog-dev libgtest-dev \
		libiomp-dev libleveldb-dev liblmdb-dev libopencv-dev libopenmpi-dev \
		libsnappy-dev libprotobuf-dev openmpi-bin openmpi-doc \
		protobuf-compiler libgflags-dev $(CAFFE2_PY$(1)_PACKAGES)
	$(ACBUILD$@) run -- pip$(1) install future numpy protobuf

	# Relink python to use pythonX
	$(ACBUILD$@) run -- ln -sf python$(1) /usr/bin/python

	$(ACBUILD$@) run -- git clone https://github.com/caffe2/caffe2.git /caffe2
	$(ACBUILD$@) run -- sh -c 'cd /caffe2 && git checkout 4f534fad1af9f77d4f0496ecd37dafb382330223'
	$(ACBUILD$@) run -- sh -c 'cd /caffe2 && git submodule update --init'

	# Build with native optimizations
	$(ACBUILD$@) run -- sed -i 's/\(option(USE_NATIVE_ARCH.* \)OFF)/\1$(CAFFE2_NATIVE_ARCH))/' /caffe2/CMakeLists.txt

	# Use 8 threads for now
	$(ACBUILD$@) run -- sh -c 'cd /caffe2 && make -j8 && cd build && make install'
	$(ACBUILD$@) run -- rm -rf /caffe2

	# Caffe2 has a broken install, symlink it into the python path
	$(ACBUILD$@) run -- sh -c "ln -sf /usr/local/caffe2 /usr/local/caffe \
		$$(python -c 'import sys, os.path; print(list(filter(os.path.isdir, sys.path))[0])')"

	# Ubuntu does not index libs under /usr/local/lib/, update ldconfig
	$(ACBUILD$@) run -- sh -c 'echo /usr/local/lib/ > /etc/ld.so.conf.d/usr-local-lib.conf'
	$(ACBUILD$@) run -- ldconfig

	# Caffe2 needs some extra syscalls enabled to work
	$(ACBUILD$@) isolator add "os/linux/seccomp-retain-set" files/caffe2/extra_caps

	$(acbuild_finalize_cleanup)
endef

$(call gen_acbuild,caffe2-py2-nogpu)
caffe2-py2-nogpu.aci: build-xbase.aci files/caffe2/extra_caps
	$(call caffe2_recipe,2)

$(call gen_acbuild,caffe2-py2-gpu)
caffe2-py2-gpu.aci: cudnn.aci files/caffe2/extra_caps
	$(call caffe2_recipe,2)

$(call gen_acbuild,caffe2-py3-nogpu)
caffe2-py3-nogpu.aci: build-xbase.aci files/caffe2/extra_caps
	$(call caffe2_recipe,3)

$(call gen_acbuild,caffe2-py3-gpu)
caffe2-py3-gpu.aci: cudnn.aci files/caffe2/extra_caps
	$(call caffe2_recipe,3)

include Makefile.apps
