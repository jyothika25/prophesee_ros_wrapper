#include <mutex>
#include <thread>

#include <ros/ros.h>
#include <std_msgs/String.h>
#include <sensor_msgs/image_encodings.h>
#include <cv_bridge/cv_bridge.h>
#include <metavision/sdk/core/algorithms/periodic_frame_generation_algorithm.h> 
#include <sensor_msgs/Image.h> 
#include <image_transport/image_transport.h>
#include <prophesee_event_msgs/Event.h>
#include <prophesee_event_msgs/EventArray.h>
#include "rospublisher.h"
#include <boost/date_time/posix_time/posix_time.hpp>
#include <sensor_msgs/Image.h>
#include <opencv2/highgui/highgui.hpp>
#if CV_MAJOR_VERSION >= 4
#include <opencv2/highgui/highgui_c.h>
#endif


//modified version 19/07
PropheseeWrapperPublisher::PropheseeWrapperPublisher() :
    nh_("~"),
    biases_file_(""),
    raw_file_to_read_(""),
    display_acc_time_(5000), 
    initialized_(false)  {   
   
    camera_name_ = "PropheseeCamera_optical_frame";
    
    // Load Parameters
    nh_.getParam("camera_name", camera_name_);
    nh_.getParam("publish_cd", publish_cd_);
    nh_.getParam("bias_file", biases_file_);
    nh_.getParam("raw_file_to_read", raw_file_to_read_);
    event_delta_t_ = ros::Duration(nh_.param<double>("event_delta_t", 100.0e-6));

    const std::string topic_cam_info        = "/prophesee/" + camera_name_ + "/camera_info";
    const std::string topic_cd_event_buffer = "/prophesee/" + camera_name_ + "/cd_events_buffer";
    pub_info_ = nh_.advertise<sensor_msgs::CameraInfo>(topic_cam_info, 1);

    
    // Create a publisher for the image message
    pub_frames = nh_.advertise<sensor_msgs::Image>("/topic_frames", 10);
    if (publish_cd_)
        pub_cd_events_ = nh_.advertise<prophesee_event_msgs::EventArray>(topic_cd_event_buffer, 500);



    while (!openCamera()) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        ROS_INFO("Trying to open camera...");
    }

    // Add camera runtime error callback
    camera_.add_runtime_error_callback([](const Metavision::CameraException &e) { ROS_WARN("%s", e.what()); });

    // Get the sensor config
    Metavision::CameraConfiguration config = camera_.get_camera_configuration();
    auto &geometry                        = camera_.geometry();
    ROS_INFO("[CONF] Width:%i, Height:%i", geometry.width(), geometry.height());
    ROS_INFO("[CONF] Serial number: %s", config.serial_number.c_str());
    // Publish camera info message
    cam_info_msg_.width           = geometry.width();
    cam_info_msg_.height          = geometry.height();
    cam_info_msg_.header.frame_id = "PropheseeCamera_optical_frame";
}

PropheseeWrapperPublisher::~PropheseeWrapperPublisher() {
    
     if (!initialized_)
        return;

    // Stop the CD frame generator thread
    if (show_cd_)
        cd_frame_generator_.stop();
    // Destroy the windows
    cv::destroyAllWindows();
    camera_.stop();
    nh_.shutdown();
}

bool PropheseeWrapperPublisher::openCamera() {
    bool camera_is_opened = false;

    // Initialize the camera instance
    try {
        if (raw_file_to_read_.empty()) {
            camera_ = Metavision::Camera::from_first_available();

            if (!biases_file_.empty()) {
                ROS_INFO("[CONF] Loading bias file: %s", biases_file_.c_str());
                camera_.biases().set_from_file(biases_file_);
            }
        } else {
            camera_ = Metavision::Camera::from_file(raw_file_to_read_);
            ROS_INFO("[CONF] Reading from raw file: %s", raw_file_to_read_.c_str());
        }

        camera_is_opened = true;
    } catch (Metavision::CameraException &e) { ROS_WARN("%s", e.what()); }
    return camera_is_opened;
}

void PropheseeWrapperPublisher::startPublishing() {
    camera_.start();
    start_timestamp_ = ros::Time::now();
    last_timestamp_  = start_timestamp_;

    if (publish_cd_)
        publishCDEvents();
        
    ros::Rate loop_rate(5);
    while (ros::ok()) {
        if (pub_info_.getNumSubscribers() > 0) {
            /** Get and publish camera info **/
            cam_info_msg_.header.stamp = ros::Time::now();
            pub_info_.publish(cam_info_msg_);
        }
        loop_rate.sleep();
    }
    
}

void PropheseeWrapperPublisher::publishCDEvents() {
    // Initialize and publish a buffer of CD events
    try {
        Metavision::CallbackId cd_callback =
            camera_.cd().add_callback([this](const Metavision::EventCD *ev_begin, const Metavision::EventCD *ev_end) {
                // Check the number of subscribers to the topic
                if (pub_cd_events_.getNumSubscribers() <= 0)
                    return;

                if (ev_begin < ev_end) {
                    // Compute the current local buffer size with new CD events
                    const unsigned int buffer_size = ev_end - ev_begin;

                    // Get the current time
                    event_buffer_current_time_.fromNSec(start_timestamp_.toNSec() + (ev_begin->t * 1000.00));

                    /** In case the buffer is empty we set the starting timestamp **/
                    if (event_buffer_.empty()) {
                        // Get starting time
                        event_buffer_start_time_ = event_buffer_current_time_;
                    }

                    /** Insert the events to the buffer **/
                    auto inserter = std::back_inserter(event_buffer_);

                    /** When there is not activity filter **/
                    std::copy(ev_begin, ev_end, inserter);

                    /** Get the last timestamp **/
                    event_buffer_current_time_.fromNSec(start_timestamp_.toNSec() + (ev_end - 1)->t * 1000.00);
                }

                if ((event_buffer_current_time_ - event_buffer_start_time_) >= event_delta_t_) {
                    /** Create the message **/
                    prophesee_event_msgs::EventArray event_buffer_msg;

                    // Sensor geometry in header of the message
                    event_buffer_msg.header.stamp = event_buffer_current_time_;
                    event_buffer_msg.height       = camera_.geometry().height();
                    event_buffer_msg.width        = camera_.geometry().width();

                    /** Set the buffer size for the msg **/
                    event_buffer_msg.events.resize(event_buffer_.size());

                    // Copy the events to the ros buffer format
                    auto buffer_msg_it = event_buffer_msg.events.begin();
                    for (const Metavision::EventCD *it = std::addressof(event_buffer_[0]);
                         it != std::addressof(event_buffer_[event_buffer_.size()]); ++it, ++buffer_msg_it) {
                        prophesee_event_msgs::Event &event = *buffer_msg_it;
                        event.x                            = it->x;
                        event.y                            = it->y;
                        event.polarity                     = it->p;
                        event.ts.fromNSec(start_timestamp_.toNSec() + (it->t * 1000.00));
                    }

                    // Publish the message
                    pub_cd_events_.publish(event_buffer_msg);

                    // Clean the buffer for the next iteration
                    event_buffer_.clear();

                    ROS_DEBUG("CD data available, buffer size: %d at time: %lui",
                              static_cast<int>(event_buffer_msg.events.size()), event_buffer_msg.header.stamp.toNSec());
                }

            });
    } catch (Metavision::CameraException &e) {
        ROS_WARN("%s", e.what());
        publish_cd_ = false;
    }
}


bool PropheseeWrapperPublisher::isInitialized() {
    return initialized_;
}


 
//Publishing frames
void PropheseeWrapperPublisher::publishframes(){
    ROS_INFO("Publishing generated frames");
    const auto w = camera_.geometry().width();
    const auto h = camera_.geometry().height();
    const std::uint32_t acc = 20000;
    double fps = 30;
    auto frame_gen = Metavision::PeriodicFrameGenerationAlgorithm(w, h, acc, fps);
    
    
   

    frame_gen.set_output_callback([&](Metavision::timestamp, cv::Mat &frame){
       
        sensor_msgs::ImagePtr msg = cv_bridge::CvImage(std_msgs::Header(), "bgr8", frame).toImageMsg(); 
        pub_frames.publish(msg);
        
    });

    camera_.cd().add_callback([&](const Metavision::EventCD *begin, const Metavision::EventCD *end){
        frame_gen.process_events(begin, end);
    });

    camera_.start();
    start_timestamp_ = ros::Time::now();
    last_timestamp_  = start_timestamp_;
    
    while(camera_.is_running()){
       //Keep running 
        
        
        
    }
    
    camera_.stop();

    
    
}
    


int main(int argc, char **argv) {
    ros::init(argc, argv, "rospublisher");
    PropheseeWrapperPublisher wp;
   
    //wp.startPublishing(); //uncomment for publishing CD events
   
    wp.publishframes();

    
   
    ROS_INFO("Published frame msg");
    
    
    ros::shutdown();

    return 0;
}
