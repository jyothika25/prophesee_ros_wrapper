cmake_minimum_required(VERSION 2.8.3)
project(prophesee_ros_driver)

## Compile as C++11, supported in ROS Kinetic and newer
add_compile_options(-std=c++14)


execute_process(COMMAND lsb_release -cs OUTPUT_VARIABLE RELEASE_CODENAME OUTPUT_STRIP_TRAILING_WHITESPACE)

find_package(OpenCV COMPONENTS highgui REQUIRED)

find_package(catkin REQUIRED COMPONENTS
        OpenCV
        roscpp
        sensor_msgs
        cv_bridge
        image_transport
        prophesee_event_msgs
        genmsg
        message_generation
)

find_package(MetavisionSDK COMPONENTS driver REQUIRED)

if (CATKIN_ENABLE_TESTING)
  find_package(roslaunch REQUIRED)
  roslaunch_add_file_check(launch)
endif()

catkin_package(
  INCLUDE_DIRS include/${PROJECT_NAME}/
  LIBRARIES ${PROJECT_NAME}
  CATKIN_DEPENDS roscpp sensor_msgs cv_bridge image_transport prophesee_event_msgs
)

###########
## Build ##
###########

include_directories(
  include/${PROJECT_NAME}
  ${catkin_INCLUDE_DIRS}
  ${OPENCV_INCLUDE_DIRS}
)


#rospublisher
add_executable(rospublisher 
      src/rospublisher.cpp
      src/cd_frame_generator.cpp)
target_link_libraries(
    rospublisher
    MetavisionSDK::driver
    ${catkin_LIBRARIES}
)

add_dependencies(
    rospublisher
    prophesee_event_msgs_generate_messages_cpp
    ${catkin_EXPORTED_TARGETS}
)


#rosviewer
add_executable(rosviewer
    src/rosviewer.cpp
    src/cd_frame_generator.cpp
    
)

target_link_libraries(
    rosviewer
    MetavisionSDK::driver
    ${catkin_LIBRARIES}
)

add_dependencies(
    rosviewer
    prophesee_event_msgs_generate_messages_cpp
    ${catkin_EXPORTED_TARGETS}
)

