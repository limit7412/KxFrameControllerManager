module SteamVR
  # libopenvr_api.so の最小バインディング（仕様書 4.1 節、5.2 節）。
  #
  # libopenvr_api.so は同梱せず、SteamVR がインストールしたものを実行時に探して dlopen する。
  # 動的ロードの関数は標準ライブラリの LibC（dlopen、dlsym、dlclose、dlerror）を使い、
  # OpenVR 側の関数は dlsym で解決する。
  # この宣言を参照するのは同じコンテキストの openvr_repository.cr だけとする。
  #
  # FnTable の構造体は openvr_capi.h から機械的に写したものである。
  # 呼ぶ関数だけを型付きの Proc へ変換して使うため、要素はすべて関数ポインタとして宣言する。
  # 並び順そのものが ABI であり、要素を 1 つでも増減させると呼び出し先がずれる。
  lib LibOpenVR
    # EVRApplicationType_VRApplication_Background
    #
    # SteamVR が動いていなければ、起動せずに初期化のほうを失敗させる唯一の種別である。
    # Overlay（2）や Scene（1）では、動いていなければ SteamVR が起動される。
    APPLICATION_TYPE_BACKGROUND = 3
    # EVRInitError_VRInitError_None と EVRApplicationError_VRApplicationError_None
    ERROR_NONE = 0
    # EVRInitError_VRInitError_Init_NoServerForBackgroundApp
    #
    # Background で初期化したときに、SteamVR が動いていないことを表す。
    # 初期化の失敗のうち、これだけは異常ではない。
    ERROR_NO_SERVER_FOR_BACKGROUND_APP = 121

    # EVREventType の値のうち、本ツールが読み分けるもの。
    EVENT_TRACKED_DEVICE_ACTIVATED   = 100
    EVENT_TRACKED_DEVICE_DEACTIVATED = 101
    EVENT_QUIT                       = 700

    # 設定画面（ダッシュボードのタブ）で使う値。
    # EVREventType のうち、オーバーレイに届くもの。
    EVENT_MOUSE_BUTTON_UP = 302
    EVENT_OVERLAY_SHOWN   = 500
    # VROverlayInputMethod_Mouse
    OVERLAY_INPUT_METHOD_MOUSE = 1
    # EVROverlayError_VROverlayError_KeyInUse。前の接続のオーバーレイが残っているときに返る。
    OVERLAY_ERROR_KEY_IN_USE = 17
    # k_ulOverlayHandleInvalid
    OVERLAY_HANDLE_INVALID = 0_u64

    # HmdVector2_t
    struct HmdVector2
      x : Float32
      y : Float32
    end

    # EVRInputError_VRInputError_None と EVRSettingsError_VRSettingsError_None
    INPUT_ERROR_NONE    = 0
    SETTINGS_ERROR_NONE = 0
    # EVRSettingsError_VRSettingsError_UnsetSettingHasNoDefault
    #
    # 値が書かれておらず既定値も無いキーを読んだときに返る。
    # 省電力で「元は未設定だった」と判断するのに使う（仕様書 3.8 節）。
    SETTINGS_ERROR_UNSET_HAS_NO_DEFAULT = 5
    # ETrackedPropertyError_TrackedProp_Success
    PROPERTY_SUCCESS = 0

    # ETrackedControllerRole
    CONTROLLER_ROLE_LEFT_HAND  = 1
    CONTROLLER_ROLE_RIGHT_HAND = 2

    # k_unTrackedDeviceIndex_Hmd と k_unTrackedDeviceIndexInvalid
    TRACKED_DEVICE_INDEX_HMD     =          0_u32
    TRACKED_DEVICE_INDEX_INVALID = 0xFFFFFFFF_u32

    # ETrackedDeviceProperty のうち、本ツールが読むもの。
    PROP_SERIAL_NUMBER_STRING              = 1002
    PROP_DISPLAY_SUPPORTS_ANALOG_GAIN_BOOL = 2085
    PROP_DISPLAY_MIN_ANALOG_GAIN_FLOAT     = 2086
    PROP_DISPLAY_MAX_ANALOG_GAIN_FLOAT     = 2087

    # k_unMaxPropertyStringSize。文字列のプロパティと設定値を読むバッファの大きさに使う。
    MAX_PROPERTY_STRING_SIZE = 32768

    # k_nActionSetOverlayGlobalPriorityMin（仕様書 3.1 節）
    ACTION_SET_OVERLAY_GLOBAL_PRIORITY_MIN = 0x01000000

    # InputDigitalActionData_t。
    #
    # VREvent_t と違い、#pragma pack の指定の外にあるため自然な境界で並ぶ。
    # bool の後ろに 7 バイト、2 つ目の bool の組の後ろに 2 バイトの詰め物が入り、全体は 24 バイトである。
    # Crystal の struct も C と同じ規則で詰め物を入れる。
    struct InputDigitalActionData
      active : Bool
      active_origin : UInt64
      state : Bool
      changed : Bool
      update_time : Float32
    end

    # VRActiveActionSet_t（32 バイト）。
    struct VRActiveActionSet
      action_set : UInt64
      restricted_to_device : UInt64
      secondary_action_set : UInt64
      padding : UInt32
      priority : Int32
    end

    # VREvent_t。
    #
    # openvr_capi.h は Windows 以外で 4 バイト境界に詰める（#pragma pack( push, 4 )）。
    # data は最大の要素が VREvent_Reserved_t（uint64 が 6 つ）の共用体で 48 バイトになり、
    # 全体は 12 + 48 = 60 バイトである。
    # data の中身はまだ使わないため、大きさだけを合わせたバイト列として宣言する。
    # 1 バイト境界のバイト列にしてあるので、Crystal 側でも詰め物は入らない。
    struct VREvent
      event_type : UInt32
      tracked_device_index : UInt32
      event_age_seconds : Float32
      data : UInt8[48]
    end

    # VR_IVRSystem_FnTable（要素数 51）
    struct IVRSystemFnTable
      get_recommended_render_target_size : Void*                      # GetRecommendedRenderTargetSize
      get_projection_matrix : Void*                                   # GetProjectionMatrix
      get_projection_raw : Void*                                      # GetProjectionRaw
      compute_distortion : Void*                                      # ComputeDistortion
      compute_distortion_set : Void*                                  # ComputeDistortionSet
      get_eye_to_head_transform : Void*                               # GetEyeToHeadTransform
      get_time_since_last_vsync : Void*                               # GetTimeSinceLastVsync
      get_d3_d9_adapter_index : Void*                                 # GetD3D9AdapterIndex
      get_d_x_g_i_output_info : Void*                                 # GetDXGIOutputInfo
      get_output_device : Void*                                       # GetOutputDevice
      is_display_on_desktop : Void*                                   # IsDisplayOnDesktop
      set_display_visibility : Void*                                  # SetDisplayVisibility
      get_device_to_absolute_tracking_pose : Void*                    # GetDeviceToAbsoluteTrackingPose
      get_seated_zero_pose_to_standing_absolute_tracking_pose : Void* # GetSeatedZeroPoseToStandingAbsoluteTrackingPose
      get_raw_zero_pose_to_standing_absolute_tracking_pose : Void*    # GetRawZeroPoseToStandingAbsoluteTrackingPose
      get_sorted_tracked_device_indices_of_class : Void*              # GetSortedTrackedDeviceIndicesOfClass
      get_tracked_device_activity_level : Void*                       # GetTrackedDeviceActivityLevel
      apply_transform : Void*                                         # ApplyTransform
      get_tracked_device_index_for_controller_role : Void*            # GetTrackedDeviceIndexForControllerRole
      get_controller_role_for_tracked_device_index : Void*            # GetControllerRoleForTrackedDeviceIndex
      get_tracked_device_class : Void*                                # GetTrackedDeviceClass
      is_tracked_device_connected : Void*                             # IsTrackedDeviceConnected
      get_bool_tracked_device_property : Void*                        # GetBoolTrackedDeviceProperty
      get_float_tracked_device_property : Void*                       # GetFloatTrackedDeviceProperty
      get_int32_tracked_device_property : Void*                       # GetInt32TrackedDeviceProperty
      get_uint64_tracked_device_property : Void*                      # GetUint64TrackedDeviceProperty
      get_matrix34_tracked_device_property : Void*                    # GetMatrix34TrackedDeviceProperty
      get_array_tracked_device_property : Void*                       # GetArrayTrackedDeviceProperty
      get_string_tracked_device_property : Void*                      # GetStringTrackedDeviceProperty
      get_prop_error_name_from_enum : Void*                           # GetPropErrorNameFromEnum
      poll_next_event : Void*                                         # PollNextEvent
      poll_next_event_with_pose : Void*                               # PollNextEventWithPose
      poll_next_event_with_pose_and_overlays : Void*                  # PollNextEventWithPoseAndOverlays
      get_event_type_name_from_enum : Void*                           # GetEventTypeNameFromEnum
      get_hidden_area_mesh : Void*                                    # GetHiddenAreaMesh
      get_eye_tracked_foveation_center : Void*                        # GetEyeTrackedFoveationCenter
      get_eye_tracked_foveation_center_for_projection : Void*         # GetEyeTrackedFoveationCenterForProjection
      get_controller_state : Void*                                    # GetControllerState
      get_controller_state_with_pose : Void*                          # GetControllerStateWithPose
      trigger_haptic_pulse : Void*                                    # TriggerHapticPulse
      get_button_id_name_from_enum : Void*                            # GetButtonIdNameFromEnum
      get_controller_axis_type_name_from_enum : Void*                 # GetControllerAxisTypeNameFromEnum
      is_input_available : Void*                                      # IsInputAvailable
      is_steam_v_r_drawing_controllers : Void*                        # IsSteamVRDrawingControllers
      should_application_pause : Void*                                # ShouldApplicationPause
      should_application_reduce_rendering_work : Void*                # ShouldApplicationReduceRenderingWork
      perform_firmware_update : Void*                                 # PerformFirmwareUpdate
      acknowledge_quit_exiting : Void*                                # AcknowledgeQuit_Exiting
      get_app_container_file_paths : Void*                            # GetAppContainerFilePaths
      get_runtime_version : Void*                                     # GetRuntimeVersion
      set_s_d_k_version : Void*                                       # SetSDKVersion
    end

    # VR_IVRApplications_FnTable（要素数 31）
    struct IVRApplicationsFnTable
      add_application_manifest : Void*                   # AddApplicationManifest
      remove_application_manifest : Void*                # RemoveApplicationManifest
      is_application_installed : Void*                   # IsApplicationInstalled
      get_application_count : Void*                      # GetApplicationCount
      get_application_key_by_index : Void*               # GetApplicationKeyByIndex
      get_application_key_by_process_id : Void*          # GetApplicationKeyByProcessId
      launch_application : Void*                         # LaunchApplication
      launch_template_application : Void*                # LaunchTemplateApplication
      launch_application_from_mime_type : Void*          # LaunchApplicationFromMimeType
      launch_dashboard_overlay : Void*                   # LaunchDashboardOverlay
      cancel_application_launch : Void*                  # CancelApplicationLaunch
      identify_application : Void*                       # IdentifyApplication
      get_application_process_id : Void*                 # GetApplicationProcessId
      get_applications_error_name_from_enum : Void*      # GetApplicationsErrorNameFromEnum
      get_application_property_string : Void*            # GetApplicationPropertyString
      get_application_property_bool : Void*              # GetApplicationPropertyBool
      get_application_property_uint64 : Void*            # GetApplicationPropertyUint64
      set_application_auto_launch : Void*                # SetApplicationAutoLaunch
      get_application_auto_launch : Void*                # GetApplicationAutoLaunch
      set_default_application_for_mime_type : Void*      # SetDefaultApplicationForMimeType
      get_default_application_for_mime_type : Void*      # GetDefaultApplicationForMimeType
      get_application_supported_mime_types : Void*       # GetApplicationSupportedMimeTypes
      get_applications_that_support_mime_type : Void*    # GetApplicationsThatSupportMimeType
      get_application_launch_arguments : Void*           # GetApplicationLaunchArguments
      get_starting_application : Void*                   # GetStartingApplication
      get_scene_application_state : Void*                # GetSceneApplicationState
      perform_application_prelaunch_check : Void*        # PerformApplicationPrelaunchCheck
      get_scene_application_state_name_from_enum : Void* # GetSceneApplicationStateNameFromEnum
      launch_internal_process : Void*                    # LaunchInternalProcess
      register_subprocess : Void*                        # RegisterSubprocess
      get_current_scene_process_id : Void*               # GetCurrentSceneProcessId
    end

    # VR_IVRInput_FnTable（要素数 34）
    struct IVRInputFnTable
      set_action_manifest_path : Void*              # SetActionManifestPath
      get_action_set_handle : Void*                 # GetActionSetHandle
      get_action_handle : Void*                     # GetActionHandle
      get_input_source_handle : Void*               # GetInputSourceHandle
      update_action_state : Void*                   # UpdateActionState
      get_digital_action_data : Void*               # GetDigitalActionData
      get_analog_action_data : Void*                # GetAnalogActionData
      get_pose_action_data_relative_to_now : Void*  # GetPoseActionDataRelativeToNow
      get_pose_action_data_for_next_frame : Void*   # GetPoseActionDataForNextFrame
      get_skeletal_action_data : Void*              # GetSkeletalActionData
      get_dominant_hand : Void*                     # GetDominantHand
      set_dominant_hand : Void*                     # SetDominantHand
      get_eye_tracking_data_relative_to_now : Void* # GetEyeTrackingDataRelativeToNow
      get_eye_tracking_data_for_next_frame : Void*  # GetEyeTrackingDataForNextFrame
      get_bone_count : Void*                        # GetBoneCount
      get_bone_hierarchy : Void*                    # GetBoneHierarchy
      get_bone_name : Void*                         # GetBoneName
      get_skeletal_reference_transforms : Void*     # GetSkeletalReferenceTransforms
      get_skeletal_tracking_level : Void*           # GetSkeletalTrackingLevel
      get_skeletal_bone_data : Void*                # GetSkeletalBoneData
      get_skeletal_summary_data : Void*             # GetSkeletalSummaryData
      get_skeletal_bone_data_compressed : Void*     # GetSkeletalBoneDataCompressed
      decompress_skeletal_bone_data : Void*         # DecompressSkeletalBoneData
      trigger_haptic_vibration_action : Void*       # TriggerHapticVibrationAction
      get_action_origins : Void*                    # GetActionOrigins
      get_origin_localized_name : Void*             # GetOriginLocalizedName
      get_origin_tracked_device_info : Void*        # GetOriginTrackedDeviceInfo
      get_action_binding_info : Void*               # GetActionBindingInfo
      show_action_origins : Void*                   # ShowActionOrigins
      show_bindings_for_action_set : Void*          # ShowBindingsForActionSet
      get_component_state_for_binding : Void*       # GetComponentStateForBinding
      is_using_legacy_input : Void*                 # IsUsingLegacyInput
      open_binding_u_i : Void*                      # OpenBindingUI
      get_binding_variant : Void*                   # GetBindingVariant
    end

    # VR_IVRSettings_FnTable（要素数 11）
    struct IVRSettingsFnTable
      get_settings_error_name_from_enum : Void* # GetSettingsErrorNameFromEnum
      set_bool : Void*                          # SetBool
      set_int32 : Void*                         # SetInt32
      set_float : Void*                         # SetFloat
      set_string : Void*                        # SetString
      get_bool : Void*                          # GetBool
      get_int32 : Void*                         # GetInt32
      get_float : Void*                         # GetFloat
      get_string : Void*                        # GetString
      remove_section : Void*                    # RemoveSection
      remove_key_in_section : Void*             # RemoveKeyInSection
    end

    # VR_IVROverlay_FnTable（要素数 82）。設定画面をダッシュボードのタブとして出すのに使う。
    struct IVROverlayFnTable
      find_overlay : Void*                                   # FindOverlay
      create_overlay : Void*                                 # CreateOverlay
      create_subview_overlay : Void*                         # CreateSubviewOverlay
      destroy_overlay : Void*                                # DestroyOverlay
      get_overlay_key : Void*                                # GetOverlayKey
      get_overlay_name : Void*                               # GetOverlayName
      set_overlay_name : Void*                               # SetOverlayName
      get_overlay_image_data : Void*                         # GetOverlayImageData
      get_overlay_error_name_from_enum : Void*               # GetOverlayErrorNameFromEnum
      set_overlay_rendering_pid : Void*                      # SetOverlayRenderingPid
      get_overlay_rendering_pid : Void*                      # GetOverlayRenderingPid
      set_overlay_flag : Void*                               # SetOverlayFlag
      get_overlay_flag : Void*                               # GetOverlayFlag
      get_overlay_flags : Void*                              # GetOverlayFlags
      set_overlay_color : Void*                              # SetOverlayColor
      get_overlay_color : Void*                              # GetOverlayColor
      set_overlay_alpha : Void*                              # SetOverlayAlpha
      get_overlay_alpha : Void*                              # GetOverlayAlpha
      set_overlay_texel_aspect : Void*                       # SetOverlayTexelAspect
      get_overlay_texel_aspect : Void*                       # GetOverlayTexelAspect
      set_overlay_sort_order : Void*                         # SetOverlaySortOrder
      get_overlay_sort_order : Void*                         # GetOverlaySortOrder
      set_overlay_width_in_meters : Void*                    # SetOverlayWidthInMeters
      get_overlay_width_in_meters : Void*                    # GetOverlayWidthInMeters
      set_overlay_curvature : Void*                          # SetOverlayCurvature
      get_overlay_curvature : Void*                          # GetOverlayCurvature
      set_overlay_pre_curve_pitch : Void*                    # SetOverlayPreCurvePitch
      get_overlay_pre_curve_pitch : Void*                    # GetOverlayPreCurvePitch
      set_overlay_texture_color_space : Void*                # SetOverlayTextureColorSpace
      get_overlay_texture_color_space : Void*                # GetOverlayTextureColorSpace
      set_overlay_texture_bounds : Void*                     # SetOverlayTextureBounds
      get_overlay_texture_bounds : Void*                     # GetOverlayTextureBounds
      get_overlay_transform_type : Void*                     # GetOverlayTransformType
      set_overlay_transform_absolute : Void*                 # SetOverlayTransformAbsolute
      get_overlay_transform_absolute : Void*                 # GetOverlayTransformAbsolute
      set_overlay_transform_tracked_device_relative : Void*  # SetOverlayTransformTrackedDeviceRelative
      get_overlay_transform_tracked_device_relative : Void*  # GetOverlayTransformTrackedDeviceRelative
      set_overlay_transform_tracked_device_component : Void* # SetOverlayTransformTrackedDeviceComponent
      get_overlay_transform_tracked_device_component : Void* # GetOverlayTransformTrackedDeviceComponent
      set_overlay_transform_cursor : Void*                   # SetOverlayTransformCursor
      get_overlay_transform_cursor : Void*                   # GetOverlayTransformCursor
      set_overlay_transform_projection : Void*               # SetOverlayTransformProjection
      set_subview_position : Void*                           # SetSubviewPosition
      show_overlay : Void*                                   # ShowOverlay
      hide_overlay : Void*                                   # HideOverlay
      is_overlay_visible : Void*                             # IsOverlayVisible
      get_transform_for_overlay_coordinates : Void*          # GetTransformForOverlayCoordinates
      wait_frame_sync : Void*                                # WaitFrameSync
      poll_next_overlay_event : Void*                        # PollNextOverlayEvent
      get_overlay_input_method : Void*                       # GetOverlayInputMethod
      set_overlay_input_method : Void*                       # SetOverlayInputMethod
      get_overlay_mouse_scale : Void*                        # GetOverlayMouseScale
      set_overlay_mouse_scale : Void*                        # SetOverlayMouseScale
      compute_overlay_intersection : Void*                   # ComputeOverlayIntersection
      is_hover_target_overlay : Void*                        # IsHoverTargetOverlay
      set_overlay_intersection_mask : Void*                  # SetOverlayIntersectionMask
      trigger_laser_mouse_haptic_vibration : Void*           # TriggerLaserMouseHapticVibration
      set_overlay_cursor : Void*                             # SetOverlayCursor
      set_overlay_cursor_position_override : Void*           # SetOverlayCursorPositionOverride
      clear_overlay_cursor_position_override : Void*         # ClearOverlayCursorPositionOverride
      set_overlay_texture : Void*                            # SetOverlayTexture
      clear_overlay_texture : Void*                          # ClearOverlayTexture
      set_overlay_raw : Void*                                # SetOverlayRaw
      set_overlay_from_file : Void*                          # SetOverlayFromFile
      get_overlay_texture : Void*                            # GetOverlayTexture
      release_native_overlay_handle : Void*                  # ReleaseNativeOverlayHandle
      get_overlay_texture_size : Void*                       # GetOverlayTextureSize
      create_dashboard_overlay : Void*                       # CreateDashboardOverlay
      is_dashboard_visible : Void*                           # IsDashboardVisible
      is_active_dashboard_overlay : Void*                    # IsActiveDashboardOverlay
      set_dashboard_overlay_scene_process : Void*            # SetDashboardOverlaySceneProcess
      get_dashboard_overlay_scene_process : Void*            # GetDashboardOverlaySceneProcess
      show_dashboard : Void*                                 # ShowDashboard
      get_primary_dashboard_device : Void*                   # GetPrimaryDashboardDevice
      show_keyboard : Void*                                  # ShowKeyboard
      show_keyboard_for_overlay : Void*                      # ShowKeyboardForOverlay
      get_keyboard_text : Void*                              # GetKeyboardText
      hide_keyboard : Void*                                  # HideKeyboard
      set_keyboard_transform_absolute : Void*                # SetKeyboardTransformAbsolute
      set_keyboard_position_for_overlay : Void*              # SetKeyboardPositionForOverlay
      show_message_overlay : Void*                           # ShowMessageOverlay
      close_message_overlay : Void*                          # CloseMessageOverlay
    end

    alias PVREvent = VREvent*
  end
end
