# This dockerfile creates an image for Jetson Xavier NX with:
# - L4T R32.7.1 (base image)
# - ROS Melodic (base image)
# - OpenCV 4.5.5
# - cv_bridge ROS <-> OpenCV Interface w/ Python 3
# - Prophesee OpenEB and its dependencies
# - Prophesee ROS wrapper
#
# Deviations from standard install procedures are denoted with
# comments that say DEBUG

ARG BUILDER=build_ARMv8

# Pull L4T+ROS base image
FROM dustynv/ros:melodic-ros-base-l4t-r32.7.1 AS buildx_x64

# ENV for build on the target, i.e. the Jetson
FROM buildx_x64 AS build_ARMv8
ENV OPENBLAS_CORETYPE=ARMV8


FROM ${BUILDER} AS setup-python3
# Setup Python 3
RUN apt-get update && apt-get -y install \
      python3-dev \
      python3-distutils \
      python3-pip && \
#     python3-tk && \
    python3 -m pip install --upgrade pip


FROM setup-python3 AS setup-dependencies
# Setup most dependencies
# DEBUG: skip libopencv-dev and compile opencv manually later; libhdf5-dev needed for h5py; get h5py from ubuntu bionic repo instead of PyPi
RUN apt-get update && apt-get -y install \
      build-essential \
      cmake \
      curl \
      ffmpeg \
      git \
      apt-utils \
      libboost-all-dev \
      libcanberra-gtk-module \
      libeigen3-dev \ 
      libglew-dev  \
      libglfw3-dev \
      libgtest-dev \
      libhdf5-dev \
      libusb-1.0-0-dev \
      software-properties-common \
      unzip \
      wget \
      # Python 3 packages
      python3-matplotlib \
      python3-numpy \
      python3-pandas \
      python3-pytest \
      python3-scipy

# DEBUG: Link needed by h5py, https://github.com/biobakery/homebrew-biobakery/issues/31
RUN ln -s /usr/include/locale.h /usr/include/xlocale.h

# DEBUG: Skip prebuilt Numba and build manually
RUN python3 -m pip install \
      "fire==0.4.0" \
      "ipywidgets==7.6.5" \
      "kornia==0.6.1" \
      "opencv-python>=4.5.5.64" \
      "pytorch_lightning==1.5.10" \
      "sk-video==1.1.10" \
      "tqdm==4.63.0" \
      jupyter \
      jupyterlab \
      profilehooks
RUN apt-get -y install python3-h5py

# DEBUG: Build Numba manually, https://support.prophesee.ai/portal/en/kb/articles/how-to-install-metavision-ml-module-on-jetson-nano
# Install LLVM 9
RUN wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key | apt-key add - && \
    apt-get update && apt-get -y install \
      clang-9 \
      libclang-9-dev \
      llvm-9-dev
ENV LLVM_CONFIG=/usr/bin/llvm-config-9
# Install llvmlite 0.34
RUN python3 -m pip install llvmlite==0.34.0
# Install Numba 0.51
WORKDIR /build
RUN wget -O numba.zip https://github.com/numba/numba/archive/refs/tags/0.51.0.zip && \
      unzip numba.zip && \
      rm numba.zip && \
      mv numba* numba
WORKDIR /build/numba
RUN python3 setup.py install

# Build pybind11 lib (required for OpenEB C++ API)
WORKDIR /build
RUN wget -O pybind11.zip https://github.com/pybind/pybind11/archive/v2.6.0.zip && \
  unzip pybind11.zip && \
  rm pybind11.zip && \
  mv pybind11* pybind11
WORKDIR /build/pybind11/build
RUN cmake .. -DPYBIND11_TEST=OFF && \
    cmake --build . -- -j $(nproc) && \
    cmake --build . --target install


FROM setup-dependencies AS build-opencv
# Compile OpenCV manually because libopencv-dev fetches opencv 3.2 on bionic, while OpenEB requires 4.5
WORKDIR /build
RUN wget -O opencv.zip https://github.com/opencv/opencv/archive/refs/tags/4.5.5.zip && \
  unzip opencv.zip && \
  rm opencv.zip && \
  mv opencv* opencv
WORKDIR /build/opencv/build
RUN cmake -D CMAKE_BUILD_TYPE=RELEASE \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DOPENCV_GENERATE_PKGCONFIG=ON \
  -DBUILD_EXAMPLES=OFF \
  -DINSTALL_PYTHON_EXAMPLES=OFF \
  -DINSTALL_C_EXAMPLES=OFF \
  -DPYTHON_EXECUTABLE=$(which python2) \
  -DBUILD_opencv_python2=OFF \
  -DPYTHON3_EXECUTABLE=$(which python3) \
  -DPYTHON3_INCLUDE_DIR=$(python3 -c "from distutils.sysconfig import get_python_inc; print(get_python_inc())") \
  -DPYTHON3_PACKAGES_PATH=$(python3 -c "from distutils.sysconfig import get_python_lib; print(get_python_lib())") \
   ..
RUN make -j $(nproc) && \
    make install


FROM build-opencv AS build-openeb
# Build and install OpenEB
WORKDIR /build
RUN wget -O openeb.zip https://github.com/prophesee-ai/openeb/archive/refs/tags/3.1.0.zip && \
  unzip openeb.zip && \
  rm openeb.zip && \
  mv openeb* openeb && \
  rm -r openeb/hal_psee_plugins
COPY evk1_plugin.zip /build/openeb/
RUN unzip openeb/evk1_plugin.zip -d openeb/ && \
  rm openeb/evk1_plugin.zip
WORKDIR /build/openeb/build
RUN /bin/bash -c "cd /build/openeb/build; cmake .. -DBUILD_TESTING=OFF -DPYTHON3_DEFAULT_VERSION=3.6" && \
    /bin/bash -c "cd /build/openeb/build; cmake --build . --config Release -- -j $(nproc)" && \
    /bin/bash -c "cd /build/openeb/build; cmake --build . --target install" 
# RUN echo "echo \".bashrc: Setting up OpenEB environment...\"" >> /root/.bashrc
# RUN echo "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/local/lib" >> /root/.bashrc


FROM build-openeb AS build-cv-bridge
# Build and install the ROS OpenCV bridge cv_bridge
#     The ROS melodic cv_bridge delivered with the base image depends on OpenCV 3.2
#     Thus fetch cv_bridge from a fork that patches cv_bridge melodic for OpenCV 4 and Python 3
RUN apt-get update && apt-get -y install python-catkin-tools
RUN python3 -m pip install catkin_pkg
WORKDIR /build/catkin_vision_opencv
RUN git clone -b melodic https://github.com/BrutusTT/vision_opencv src/vision_opencv
RUN /bin/bash -c " \
      cd /build/catkin_vision_opencv; \
      export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/local/lib; \
      source /opt/ros/melodic/setup.bash; \
      catkin_make install cv_bridge \
        -DPYTHON_EXECUTABLE=/usr/bin/python3 \
        -DPYTHON_INCLUDE_DIR=/usr/include/python3.6m \
        -DPYTHON_LIBRARY=/usr/lib/aarch64-linux-gnu/libpython3.6m.so \
        -DCMAKE_INSTALL_PREFIX=/opt/cv_bridge/melodic \
    "


FROM build-cv-bridge AS build-ros-wrapper
# Build and install the Prophesee ROS wrapper
WORKDIR /build/catkin_prophesee_ros_wrapper
# RUN python3 -m pip install empy pyyaml
RUN git clone https://gitlab_access_token:glpat--QmiSYNpgisK4Ky-mscy@essgitlab.fzi.de/ragolu/prophesee_ros_wrapper_frame_mod.git src/prophesee_ros_wrapper
#COPY src src/.
RUN /bin/bash -c " \
      cd /build/catkin_prophesee_ros_wrapper; \
      export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/local/lib; \
      source /opt/ros/melodic/setup.bash; \
      source /opt/cv_bridge/melodic/setup.bash --extend; \
      catkin_make install -DCMAKE_INSTALL_PREFIX=/opt/prophesee_ros_wrapper/melodic"
# RUN echo "echo \".bashrc: Setting up ROS environment...\"" >> /root/.bashrc
# RUN echo "source /opt/ros/melodic/setup.bash && source /opt/cv_bridge/melodic/setup.bash --extend && source /opt/prophesee_ros_wrapper/melodic/setup.bash" >> /root/.bashrc

# Modify entrypoint script of the base image to include the new tools
WORKDIR /
RUN printf "#!/bin/bash \
\nset -e \
\n \
\n \
\necho \"Setting up OpenEB environment...\" \
\nexport LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/local/lib \
\n \
\nros_env_setup=\"/opt/ros/\$ROS_DISTRO/setup.bash\" \
\ncv_env_setup=\"/opt/cv_bridge/\$ROS_DISTRO/setup.bash\" \
\nwrapper_env_setup="/opt/prophesee_ros_wrapper/\$ROS_DISTRO/setup.bash" \
\n \
\necho \"Sourcing \$ros_env_setup, \$cv_env_setup, \$wrapper_env_setup ...\" \
\nsource \"\$ros_env_setup\" && source \"\$cv_env_setup\" --extend && source \"\$wrapper_env_setup\" --extend \
\n \
\necho \"ROS_ROOT   \$ROS_ROOT\" \
\necho \"ROS_DISTRO \$ROS_DISTRO\" \
\n \
\nexec \"\$@\"" > ros_entrypoint.sh

#FROM build-ros-wrapper
## CLEAN UP
#WORKDIR /
#RUN rm -r build
#RUN apt-get autoremove -y
#RUN rm -rf /var/lib/apt/lists/*
