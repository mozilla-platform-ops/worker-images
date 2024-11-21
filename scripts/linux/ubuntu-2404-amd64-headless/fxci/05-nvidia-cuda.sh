# copypasta'ed from https://github.com/mozilla-platform-ops/monopacker/tree/193e4d8a002f7972406c872ebc6d41011eda35b9/scripts/ubuntu-cuda
#
# cuda
cd /tmp
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt-get update
apt-get -y install cuda


# see https://developer.nvidia.com/cudnn
# steps from https://docs.nvidia.com/deeplearning/cudnn/install-guide/index.html
#   alternate resource: https://gist.github.com/valgur/fcd72fcdf5db81a826f8ff9802621d75

# official steps

UBUNTU_RELEASE=$(lsb_release -rs) # 18.04
DISTRO=ubuntu${UBUNTU_RELEASE//\./} # ubuntu1804
cuda_version="cuda12.0"
cudnn_version="8.8.1.*"

wget https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/x86_64/cuda-${DISTRO}.pin 

mv cuda-${DISTRO}.pin /etc/apt/preferences.d/cuda-repository-pin-600
apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/x86_64/3bf863cc.pub
add-apt-repository "deb https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/x86_64/ /"
apt-get update

apt-get install libcudnn8=${cudnn_version}-1+${cuda_version}
apt-get install libcudnn8-dev=${cudnn_version}-1+${cuda_version}

# see https://cloud.sylabs.io/ for more info
# steps from https://docs.sylabs.io/guides/3.11/admin-guide/installation.html

# from official deb

# pre-reqs
apt-get install -y \
   build-essential \
   libseccomp-dev \
   libglib2.0-dev \
   pkg-config \
   squashfs-tools \
   cryptsetup \
   runc \
   uidmap

# install deb
cd /tmp
wget https://github.com/sylabs/singularity/releases/download/v4.2.1/singularity-ce_4.2.1-noble_amd64.deb
dpkg -i singularity-ce_4.2.1-noble_amd64.deb
rm *.deb
