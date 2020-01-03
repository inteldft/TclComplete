#############################################
#### synopsys.tcl
#############################################

# Author: Chris Heithoff
# Description:  Procs used with WriteTclCompleteFilesSynopsys.tcl.
# Date of latest revision: 18-Dec-2019

# Bring the namespace into existence. (if not already)
namespace eval TclComplete {}

#########################################################
# Run help on a command.  Return the command's description
#########################################################
proc TclComplete::get_description_from_help {cmd} {
    set result ""
    redirect -variable help_text {help $cmd}
    # Look for <cmdname>     # Description of the command
    foreach line [split $help_text "\n"] {
        if {[regexp {^\s*(\S+)\s+(#.*$)} $line -> cmd_name description]} {
            if {$cmd_name == $cmd} {
                # For the benefit of writing JSON, add backslashes before quotes.
                set result [regsub -all {"} $description {\"}]
                # Add closing quote to make Vim happy " 
            }
        }
    }
    return $result 
}

#########################################################
# Run man on a command.  Return the command's description
#########################################################
proc TclComplete::get_description_from_man {cmd} {
    redirect -variable man_text {man $cmd}
    set man_lines [split $man_text "\n"]
    if {[regexp "No manual entry for" [lindex $man_lines 0]]} {
        return ""
    }

    # The description of the command should be in the line after the NAME line
    # Example:
    # NAME
    #        puts - Write to a channel
    coroutine next_man_line TclComplete::next_element_in_list $man_lines
    TclComplete::advance_coroutine_to next_man_line "NAME*"
    set line [next_man_line]
    set description [lindex [split $line "-"] 1]
    return "#$description"
}

#####################################################
# Run help -v on a command and then parse the options
#####################################################
proc TclComplete::get_options_from_help {cmd} {
    # Returns a dictionary.  Key = option name  Value = option detail
    set result [dict create]

    # Parse the "help -v" text for this command
    redirect -variable help_text {help -v $cmd}
    if {[regexp "CMD-040" $help_text]} {return ""}

    # First look for the command name, then look for options
    set looking_for_command 1
    set looking_for_options 0

    foreach line  [split $help_text "\n"] {
        # We need to look only in the correct section. 
        # Some help results list multiple helps (like "help -v help")
        #   This only works when the descripion is there too, preceded by #
        if {$looking_for_command} {
            if {[regexp {^\s+(\S+)\s+(#.*$)} $line -> cmd_name description]} {
                # Check for synonym
                if {[regexp -nocase {synonym for '([^']*)'} $line -> synonym]} {
                    set cmd $synonym
                } elseif {$cmd_name == $cmd} {
                    set looking_for_command 0
                    set looking_for_options 1
                    continue
                }
                
            }
        } elseif {$looking_for_options} {
            # Now get the command options which start with a dash.
            #  They might be surrounded by brackets.
            #  The option is first, then the details, surrounded by parentheses.
            if {[regexp {^\s*\[?(-[a-zA-Z0-9_]+)[^(]*(.*$)} $line -> opt detail] } {
                set detail [regsub -all {"} $detail {\"}]
                #" (comment to correct Vim syntax coloring)
                dict set result $opt $detail
            } 

            # Exit loop if there is a # sign, which indicates a second command
            # is getting listed now. (but also not including a dash)
            if {[regexp {\s*[[:alpha:]][[:alnum:]_]*\s+# } $line]} {
                break
            }
        }
    }
    return $result
}

#####################################################
# Run "man <command>".  Parse and return the options.
#####################################################
proc TclComplete::get_options_from_man {cmd} {
    set option_list {}
    redirect -variable man_text {man $cmd}
    set man_lines [split $man_text "\n"]
    if {[regexp "No manual entry for" [lindex $man_lines 0]]} {
        return ""
    }

    # Options for builtin Tcl commands can be found in at least two places
    #  1) In the SYNOPSIS section
    # Example:
    #     SYNOPSIS
    #            puts ?-nonewline? ?channelId? string
    #  2) In the DESCRIPTION section
    #  Example for lsort:
    #   -ascii Use  string  comparison  with Unicode code-point collation order
    #          (the name is for backward-compatibility reasons.)  This  is  the
    #          default.
    #
    #  3) ...or some man pages (like add_power_state) have a SYNTAX section instead
    #     Example:
    #       SYNTAX
    #          status add_power_state
    #                 [-supply ]
    #                 object_name
    coroutine next_man_line TclComplete::next_element_in_list $man_lines
    set line [next_man_line]
    
    while {[TclComplete::cmd_exists next_man_line] } {
        set line [next_man_line]
        if {$line eq "SYNOPSIS"} {
            # Find SYNOPSIS options here and return from the proc early.
            #  Expect a few Tcl builtin commands here.
            set line [next_man_line]
            set matches [regexp -all -inline {\?-[[:alpha:]]\w*} $line]
            set matches [lmap match $matches {string trim $match "?"}]
            set matches [lminus -- $matches {-option}]
            if {[llength $matches]>0} {
                foreach match $matches {
                    lappend option_list $match
                }
                return [lsort $option_list]
            }
        } elseif {$line eq "SYNTAX"} {
            # Parse lines in the SYNTAX section.
            while {[TclComplete::cmd_exists next_man_line]} {
                set line [next_man_line]
                set matches [regexp -all -inline {[-][[:alpha:]]\w*} $line]
                foreach match $matches {
                    lappend option_list $match
                } 
                if {[string is upper $line]} {
                    # The next section is indicated by an ALL_CAPS line
                    return [lsort $option_list]
                }
            }
        } elseif {$line eq "DESCRIPTION"} {
            # Parse lines in the DESCRIPTION section.
            while {[TclComplete::cmd_exists next_man_line]} {
                set line [next_man_line]
                # I wanted to use a [lindex $line 0] to get a first word, but some of
                # the lines of man page text are not friendly to list commands.  
                set line [string trim $line]
                if {[regexp {^[-][[:alpha:]]\w+} $line match]} {
                    lappend option_list $match
                } elseif {$line eq "EXAMPLES"} {
                    return [lsort -u $option_list]
                }
            }
        }
    }

    # In case we never returned inside in the while loop but exhausted the coroutine.
    return [lsort -u $option_list]
}

#####################################################
# Run "man <app_option>".  Parse and return the values
#####################################################
proc TclComplete::get_app_option_from_man_page {app_option} {
    redirect -variable man_text {man $app_option}
    set TYPE_flag 0
    set DEFAULT_flag 0
    set TYPE    ""
    set DEFAULT ""
    foreach line [split $man_text "\n"] {
        if {[regexp "^TYPE" $line]} { 
            set TYPE_flag 1
        } elseif {[regexp "^DEFAULT" $line]} { 
            set DEFAULT_flag 1
        } elseif {$TYPE_flag==1} {
            set TYPE [string trim $line]
            set TYPE_flag 0
        } elseif {$DEFAULT_flag==1} {
            set DEFAULT [string trim $line]
            # change double quotes in text to single to make json happpier later
            set DEFAULT [regsub -all "\"" $DEFAULT {'}]
            set DEFAULT_flag 0
            break
        }
    }
    if {$TYPE!=""} {
        return "$TYPE ($DEFAULT)"
    } else {
        return "unknown type"
    }
}

###########################################################################
# Use Synopsys help command for return a dictionary of command descriptions
#   Key = command name, #   Value = desciption of the command.
###########################################################################
proc TclComplete::get_descriptions {commands} {
    set desc_dict [dict create]
    foreach cmd $commands {
        # Get description of the command from Synopsys help, then from Synopsys man pages, 
        # and then finally from 'info args proc_name'.
        set description [TclComplete::get_description_from_help $cmd]
        if {$description eq "# Builtin"} {
            set description [TclComplete::get_description_from_man $cmd]
        } elseif {$description eq ""} {
            # Important to evaluate info proc at global namespace
            #   because we're stuck here in the TclComplete namespace
            if {[info proc ::${cmd}] eq "::${cmd}"} {
                set info_args [info args ::${cmd}]
                if {$info_args eq "args" || $info_args eq ""} {
                    set description ""
                } else {
                    set description "# args = $info_args"
                }
            }
        }
        dict set desc_dict $cmd $description
    }
    return $desc_dict
}

##################################################################
# Write a JSON file for command descriptions
proc TclComplete::write_descriptions_json {outdir cmd_list} {
    set desc_dict [TclComplete::get_descriptions $cmd_list]
    TclComplete::write_json $outdir/descriptions [TclComplete::dict_to_json $desc_dict] 
}

#############################################################################################
# Return a dictionary with details for each commands (by using Synopsys help or man commands)
#   details_dict:  key1=cmd, key2=option, value=detail of the option.
#############################################################################################
proc TclComplete::get_synopsys_cmd_dict {commands} {
    set cmd_dict [dict create]

    foreach cmd $commands {
        dict set details_dict $cmd [dict create]


        # Use either the 'help -v' or 'man' commands to get command options.
        set help_dict [TclComplete::get_options_from_help $cmd]
        if {[llength $help_dict]>0} {
            dict for {opt_name details} $help_dict {
                # Replace literal tabs (plus additional spaces) to a single space.
                set details [regsub {\t *} $details " "]
                dict set cmd_dict $cmd $opt_name $details
            }
        } else {
            foreach opt_name [TclComplete::get_options_from_man $cmd] {
                dict lappend cmd_dict $cmd $opt_name {}
            }
        }
    }
    return $cmd_dict
}

#########################################################
# Write a json file for Synopsys application variables
#########################################################
proc TclComplete::write_app_vars_json {outdir} {
    set app_var_list [lsort [get_app_var -list *]]
    TclComplete::write_json $outdir/app_vars [TclComplete::list_to_json $app_var_list]
}

#########################################################
# Write a json file for Synopsys application options
#########################################################
proc TclComplete::write_app_options_json {outdir} {
    # Get a list of the app options
    set app_option_dict [dict create]
    if {[TclComplete::cmd_exists  get_app_options]} {
        set app_option_list [lsort -u [get_app_options]]
    } else {
        set app_option_list {}
    }

    # Make a dictionary of app_options where the value object type (like integer, boolean, etc)
    foreach app_option $app_option_list {
        dict set app_option_dict $app_option [TclComplete::get_app_option_from_man_page $app_option]
    }

    TclComplete::write_json $outdir/app_options [TclComplete::dict_to_json $app_option_dict] 
}
#########################################################
# Write a json file for Synopsys designs 
#########################################################
proc TclComplete::write_designs_json {outdir} {
    set designs [lsort [get_attribute [get_designs -quiet] name]]
    TclComplete::write_json $outdir/designs [TclComplete::list_to_json $designs]
}

####################################################
# Write a json file for Synopsys GUI window settings
####################################################
proc TclComplete::write_gui_settings_json {outdir} {
    if {[TclComplete::cmd_exists gui_get_current_window]} {
        redirect -variable gui_settings_layout {
            set window [gui_get_current_window -types Layout -mru]
            gui_get_setting -window $window -list
        }
        # Some settings include "<layer name>" suffix.  The space leads to a
        # malformed Tcl list.  We need to replace the space with an underscore.
        set gui_settings_layout [regsub -all {<layer name>} $gui_settings_layout "<layer_name>"]
    } else {
        # In case this script is run without a GUI window open, then hardcode it.
        set gui_settings_layout {
            allowFontScaling allowVectorFont allowVerticalTextDrawing brightness cellEdgeLabelScheme
            cellFilterSize cellLabelScheme cellShape childViewName colorAirline colorBackground colorCellBackSideBump colorCellBlackBox colorCellCore colorCellCover colorCellFrontSideBump
            colorCellHardMacro colorCellIO colorCellNormalHier colorCellPhysOnly colorCellSoftMacro colorCellSpare colorCellTSV colorContactLayer_<layer_name> colorContactRegionLayer_<layer_name> colorCoreArea colorDRCDefault colorDRCSelection colorDieArea colorDrag colorEditGroup colorEditHighlight colorFPRegion colorFillInst colorForeground colorGrid colorHighlight colorIOGuide colorMovebound colorNetConnectivity colorOverlapBlockage
            colorPACore colorPAKOHard colorPAKOHardMacro colorPAKOPartial colorPAKOSoft colorPASiteArray colorPathCaptureClockPaths colorPathCells colorPathCommonClockPaths colorPathDataPaths colorPathLaunchClockPaths colorPin colorPinBlockageLayer_<layer_name> colorPinGuide colorPinLayer_<layer_name> colorPort colorPortShapeLayer_<layer_name> colorPowerplanRegion colorPreview colorRPGroup colorRPKeepout colorRailAnalysisTap colorRegion colorRegionHighlight colorRouteCorridorShape
            colorRouteGuide colorRouteGuideViaAccessPreference colorRouteGuideWireAccessPreference colorRoutedLayer_<layer_name> colorRoutingBlockageLayer_<layer_name> colorSelected colorShapingBlockage colorTextObjectLayer_<layer_name> colorTopologyEdge colorTopologyNode colorVAGuardband colorVoltageArea colorWiringGridLayer_<layer_name> customCellFiltering customObjectFilterSize customWireFilterSize deepSelect designWindow doubleBuffering eipBrightness eipShowContext expandCellCore expandCellHardMacro expandCellILM expandCellIO
            expandCellOthers expandCellSoftMacro expandFillInst fillMaskWithLayer filterBlockage filterCell filterCellBackSideBump filterCellBlackBox filterCellCore filterCellCover filterCellExtraText filterCellFlipChip filterCellFrontSideBump filterCellHardMacro filterCellIO filterCellNormalHier filterCellPhysOnly filterCellSoftMacro filterCellSpare filterCellTSV filterCellText filterCellTextArea filterContact filterContactLayers filterContactRegion
            filterCoreArea filterDieArea filterEditGroup filterFPRegion filterFillInst filterGuide filterIOGuide filterIOGuideText filterMargin filterMarginHard filterMarginHardMacro filterMarginRouteBlockage filterMarginSoft filterMovebound filterMoveboundExtraText filterMoveboundText filterNetType filterOtherLayers filterOverlapBlockage filterPACore filterPAKO filterPAKOHard filterPAKOHardMacro filterPAKOPartial filterPAKOSoft
            filterPASite filterPASiteArray filterPASiteArrayText filterPASiteText filterPin filterPinBlackBox filterPinBlockage filterPinBlockageText filterPinCellType filterPinClock filterPinCore filterPinGround filterPinGuide filterPinGuideText filterPinHardMacro filterPinNWell filterPinOthers filterPinPWell filterPinPad filterPinPower filterPinReset filterPinScan filterPinSignal filterPinSoftMacro filterPinText
            filterPinTieHigh filterPinTieLow filterPinType filterPolyContactLayers filterPolyLayers filterPort filterPortShape filterPortShapeAccess filterPortShapeText filterPortText filterPowerplanRegion filterRPGroup filterRPGroupText filterRPKeepout filterRailAnalysisTap filterRoute filterRouteCorridorShape filterRouteCorridorShapeText filterRouteGuide filterRouteGuideText filterRouteGuideViaAccessPreference filterRouteGuideWireAccessPreference filterRouteType filterRouted filterRoutedClock
            filterRoutedCoreWire filterRoutedDetailed filterRoutedFill filterRoutedFollowPin filterRoutedGRoute filterRoutedGround filterRoutedNWell filterRoutedNoNet filterRoutedOPC filterRoutedPGAugment filterRoutedPWell filterRoutedPinConMIO filterRoutedPinConStd filterRoutedPower filterRoutedRDL filterRoutedReset filterRoutedRing filterRoutedScan filterRoutedShield filterRoutedSignal filterRoutedStrap filterRoutedText filterRoutedTieHigh filterRoutedTieLow filterRoutedTrunk
            filterRoutedUser filterRoutedZeroSkew filterRoutingBlockage filterRoutingBlockageText filterRoutingLayers filterShapingBlockage filterShapingBlockageText filterText filterTextObject filterTextSelected filterTopology filterTopologyEdge filterTopologyNode filterVAGuardband filterVoltageArea filterVoltageAreaExtraText filterVoltageAreaText filterWiringGrid filterWiringGridNonPrefDir filterWiringGridPrefDir gridName hatchCellBackSideBump hatchCellBlackBox hatchCellCore hatchCellCover
            hatchCellFrontSideBump hatchCellHardMacro hatchCellIO hatchCellNormalHier hatchCellPhysOnly hatchCellSoftMacro hatchCellSpare hatchCellTSV hatchContactLayer_<layer_name> hatchContactRegionLayer_<layer_name> hatchEditGroup hatchFPRegion hatchFillInst hatchMovebound hatchOverlapBlockage hatchPACore hatchPAKOHard hatchPAKOHardMacro hatchPAKOPartial hatchPAKOSoft hatchPASiteArray hatchPinBlockageLayer_<layer_name> hatchPinGuide hatchPinLayer_<layer_name> hatchPortShapeLayer_<layer_name>
            hatchPowerplanRegion hatchRPGroup hatchRPKeepout hatchRailAnalysisTap hatchRouteCorridorShape hatchRouteGuide hatchRouteGuideViaAccessPreference hatchRouteGuideWireAccessPreference hatchRoutedLayer_<layer_name> hatchRoutingBlockageLayer_<layer_name> hatchShapingBlockage hatchTextObjectLayer_<layer_name> hatchTopologyNode hatchVAGuardband hatchVoltageArea hatchWiringGridLayer_<layer_name> infoTipLocation lineStyleCoreArea lineStyleDieArea lineStyleEditGroup lineStyleFPRegion lineStyleFillInst lineStyleMovebound lineStyleOverlapBlockage lineStylePAKOHard
            lineStylePAKOHardMacro lineStylePAKOPartial lineStylePAKOSoft lineStylePinGuide lineStylePowerplanRegion lineStyleRPGroup lineStyleRPKeepout lineStyleRailAnalysisTap lineStyleRouteGuide lineStyleShapingBlockage lineStyleTopologyEdge lineStyleTopologyNode lineStyleVAGuardband lineStyleVoltageArea lineWidthCoreArea lineWidthDieArea lineWidthEditGroup lineWidthFPRegion lineWidthFillInst lineWidthIOGuide lineWidthMovebound lineWidthOverlapBlockage lineWidthPAKOHard lineWidthPAKOHardMacro lineWidthPAKOPartial
            lineWidthPAKOSoft lineWidthPinGuide lineWidthPowerplanRegion lineWidthRPGroup lineWidthRPKeepout lineWidthRailAnalysisTap lineWidthRouteGuide lineWidthShapingBlockage lineWidthTopologyEdge lineWidthTopologyNode lineWidthVAGuardband lineWidthVoltageArea minimizeRedrawArea netRenderScheme overlayDesigns partialRedrawUpdates pathNetRenderLimit pathNetRenderScheme pathRenderLimit pinColorScheme renderAntiAlias renderQuality reverseWheel selectBlockage selectCell
            selectCellBlackBox selectCellCore selectCellCover selectCellFlipChip selectCellHardMacro selectCellIO selectCellNormalHier selectCellPhysOnly selectCellSoftMacro selectCellSpare selectCellTSV selectContact selectContactRegion selectCoreArea selectDieArea selectEditGroup selectFillInst selectGuide selectIOGuide selectLayer_<layer_name> selectMargin selectMarginHard selectMarginHardMacro selectMarginRouteBlockage selectMarginSoft
            selectMovebound selectOverlapBlockage selectPACore selectPAKO selectPASiteArray selectPin selectPinBlackBox selectPinBlockage selectPinClock selectPinCore selectPinGround selectPinGuide selectPinHardMacro selectPinNWell selectPinOthers selectPinPWell selectPinPad selectPinPower selectPinReset selectPinScan selectPinSignal selectPinSoftMacro selectPinTieHigh selectPinTieLow selectPort
            selectPortShape selectPowerplanRegion selectRPGroup selectRPKeepout selectRailAnalysisTap selectRoute selectRouteCorridorShape selectRouteGuide selectRouted selectRoutedClock selectRoutedCoreWire selectRoutedDetailed selectRoutedFill selectRoutedFollowPin selectRoutedGRoute selectRoutedGround selectRoutedNWell selectRoutedNoNet selectRoutedOPC selectRoutedPGAugment selectRoutedPWell selectRoutedPinConMIO selectRoutedPinConStd selectRoutedPower selectRoutedRDL
            selectRoutedReset selectRoutedRing selectRoutedScan selectRoutedShield selectRoutedSignal selectRoutedStrap selectRoutedTieHigh selectRoutedTieLow selectRoutedTrunk selectRoutedUser selectRoutedZeroSkew selectRoutingBlockage selectShapingBlockage selectTextObject selectTopology selectTopologyEdge selectTopologyNode selectVoltageArea selectWiringGrid shapeFilterSize shapeFilterWidthSize showBlockage showCell showCellBackSideBump showCellBlackBox
            showCellCore showCellCover showCellExtraText showCellFlipChip showCellFrontSideBump showCellHardMacro showCellIO showCellNormalHier showCellPhysOnly showCellSoftMacro showCellSpare showCellTSV showCellText showCellTextArea showColorMask showContact showContactLayer_<layer_name> showContactRegion showContactRegionLayer_<layer_name> showCoreArea showDimmed showEditGroup showFillInst showGuide showIOGuide
            showIOGuideText showInfoTip showLayer_<layer_name> showMargin showMarginHard showMarginHardMacro showMarginRouteBlockage showMarginSoft showMovebound showMoveboundExtraText showMoveboundText showOverlapBlockage showPACore showPAKO showPAKOHard showPAKOHardMacro showPAKOPartial showPAKOSoft showPASite showPASiteArray showPASiteArrayText showPASiteText showPin showPinBlackBox showPinBlockage
            showPinBlockageLayer_<layer_name> showPinBlockageText showPinClock showPinCore showPinGround showPinGuide showPinGuideText showPinHardMacro showPinLayer_<layer_name> showPinNWell showPinOthers showPinPWell showPinPad showPinPower showPinReset showPinScan showPinSignal showPinSoftMacro showPinText showPinTieHigh showPinTieLow showPort showPortShape showPortShapeAccess showPortShapeLayer_<layer_name>
            showPortShapeText showPortText showPowerplanRegion showRPGroup showRPGroupText showRPKeepout showRailAnalysisTap showRoute showRouteCorridorShape showRouteCorridorShapeText showRouteGuide showRouteGuideText showRouteGuideViaAccessPreference showRouteGuideWireAccessPreference showRouted showRoutedClock showRoutedCoreWire showRoutedDetailed showRoutedFill showRoutedFollowPin showRoutedGRoute showRoutedGround showRoutedLayer_<layer_name> showRoutedNWell showRoutedNoNet
            showRoutedOPC showRoutedPGAugment showRoutedPWell showRoutedPinConMIO showRoutedPinConStd showRoutedPower showRoutedRDL showRoutedReset showRoutedRing showRoutedScan showRoutedShield showRoutedSignal showRoutedStrap showRoutedText showRoutedTieHigh showRoutedTieLow showRoutedTrunk showRoutedUser showRoutedZeroSkew showRoutingBlockage showRoutingBlockageLayer_<layer_name> showRoutingBlockageText showScrollBars showShapingBlockage showShapingBlockageText
            showText showTextObject showTextObjectLayer_<layer_name> showTextSelected showTopology showTopologyEdge showTopologyNode showVAGuardband showViaTypeColor showVoltageArea showVoltageAreaExtraText showVoltageAreaText showWiringGrid showWiringGridLayer_<layer_name> showWiringGridNonPrefDir showWiringGridPrefDir slctStartLevel slctStopLevel timesNormalRendered timesSandboxRendered unplacedPinLocation utilizationLabeling viewLevel viewType 
        }
    }
    TclComplete::write_json $outdir/gui_settings_layout [TclComplete::list_to_json $gui_settings_layout] 
}

############################################################################
# Write json files related to the tech file
#   This will be used in the tech::get_techfile_info command's autocompletion
############################################################################
proc TclComplete::write_techfile_json {outdir} {
    ######################################################################
    # Form data structures from the ::techfile_info array
    #   techfile_types - List
    #   techfile_layers - Dict (keys = types, values = list of layers)
    #   techfile_attributes - Dict (keys = "type:layer" - values = list of attributes)
    ######################################################################
    set techfile_types {}
    set techfile_layer_dict [dict create]
    set techfile_attr_dict  [dict create]
    if {[TclComplete::cmd_exists ::tech::read_techfile_info] } {
        # This command creates the ::techfile_info array
        ::tech::read_techfile_info
        foreach name [lsort [array names ::techfile_info]] {
            lassign [split $name ":"] Type Layer
            if {$Type ni $techfile_types} {
                lappend techfile_types $Type
            }
            dict lappend techfile_layer_dict $Type $Layer
            dict set techfile_attr_dict $name [dict keys $::techfile_info($name)]
        }
    }


    TclComplete::write_json $outdir/techfile_types      [TclComplete::list_to_json $techfile_types]
    TclComplete::write_json $outdir/techfile_layer_dict [TclComplete::dict_of_lists_to_json $techfile_layer_dict]
    TclComplete::write_json $outdir/techfile_attr_dict  [TclComplete::dict_of_lists_to_json $techfile_attr_dict]
}

proc TclComplete::get_synopsys_attributes {} {
    if {![TclComplete::cmd_exists "list_attributes"]} {
        return {}
    }

    # Dump list_attributes report.
    redirect -variable attribute_list {list_attributes -nosplit}
    set attribute_list [split $attribute_list "\n"]
    set start [expr {[lsearch -glob $attribute_list "-----*"]+1}]
    set attribute_list [lrange $attribute_list $start end]

    # ...again but for -application
    redirect -variable attribute_class_list {list_attributes -nosplit -application}
    set attribute_class_list [split $attribute_class_list "\n"]
    set start [expr {[lsearch -glob $attribute_class_list "-----*"]+1}]
    set attribute_class_list [lrange $attribute_class_list $start end]

    # Pick out the first item in each line of the attribute reports.
    set attributes [list]
    foreach line [concat $attribute_list $attribute_class_list] {
        if {[llength $line]>0} {
            lappend attributes [lindex $line 0]
        }
    }
        
    return [lsort -u $attributes]
}

#############################################################
# Write a JSON file for Synopsys object class attributes
#  attribute_dict['class']['attr_name'] = choices
#############################################################
proc TclComplete::write_attributes_json {outdir} {
    set attribute_dict [dict create]

    # Dump list_attributes 
    redirect -variable attribute_list {list_attributes -nosplit}
    set attribute_list [split $attribute_list "\n"]
    set start [expr {[lsearch -glob $attribute_list "-----*"]+1}]
    set attribute_list [lrange $attribute_list $start end]

    # ...again but for -application
    redirect -variable attribute_class_list {list_attributes -nosplit -application}
    set attribute_class_list [split $attribute_class_list "\n"]
    set start [expr {[lsearch -glob $attribute_class_list "-----*"]+1}]
    set attribute_class_list [lrange $attribute_class_list $start end]

    # Now iterate over these lists to get attribute name and object class.
    foreach entry [concat $attribute_list $attribute_class_list] {
        # Skip invalid entries
        if {[llength $entry]<3} {continue}

        # Parse entry for attr_name(like "length"), attr_class(like "wire"), and attr_datatype(like "float")
        set attr_name      [lindex $entry 0]                                                 
        set attr_class     [lindex $entry 1]
        set attr_datatype  [lindex $entry 2]

        # If necessary, initialize a dict for the class of this entry
        #   and also a subdict "choices".  
        if {![dict exists $attribute_dict $attr_class]} {
            dict set attribute_dict $attr_class [dict create]
        }

        # Derive the attribute possible values (data type, or constrained list)
        if {[llength $entry]>=5} {
            set attr_choices [lrange $entry 4 end]
        } else {
            set attr_choices $attr_datatype
        }

        # Fill up the class dict: key=attr-name, value=attr_choices
        dict set attribute_dict $attr_class $attr_name $attr_choices
    }
    TclComplete::write_json $outdir/attributes [TclComplete::dict_of_dicts_to_json $attribute_dict] 
    puts "...attributes.json file complete."
}

###############################################################
# Write JSON files for G_variables (this is an Intel RDT thing)
###############################################################
proc TclComplete::write_gvars_json {outdir} {
    # G_variables.  rdt G_var names are stored in the secret ::GLOBAL_VAR::global_var
    # array.  The array name will also include comma separated keywords like history
    # and subst and constant.
    set Gvar_list {}
    set Gvar_array_list {}

    # Because this is in a proc, info var requires the global namespace ::
    foreach g_var [lsort [info var ::G_*]] {
        # If the G_var is an array, then include a leading parenthesis in the list.
        if [array exists $g_var] {
            lappend Gvar_list "${g_var}("
            foreach name [lsort [array names $g_var]] {
                lappend Gvar_array_list "${g_var}($name)"
            }
        } else {
            # Othewise, just add to list as is.
            lappend Gvar_list $g_var
        }
    }
    # Put the complete array names at the end of the list.  This is handy for the popup menu.
    set Gvar_list [concat $Gvar_list $Gvar_array_list]

    # Take off the leading colons from the lists
    set Gvar_list       [lmap g $Gvar_list       {regsub {^::} $g ""}]
    set Gvar_array_list [lmap g $Gvar_array_list {regsub {^::} $g ""}]

    # Write out the JSON files.
    TclComplete::write_json $outdir/g_vars       [TclComplete::list_to_json $Gvar_list]
    TclComplete::write_json $outdir/g_var_arrays [TclComplete::list_to_json $Gvar_array_list] 
}

######################################################################
# Write JSON files for ICC++ (itar).  This is an Intel add-on to ICC2
######################################################################
proc TclComplete::write_iccpp_json {outdir} {
    # ICCPP parameters (this will be empty if ::iccpp_com doesn't exist)
    set iccpp_param_list [lsort [array names ::iccpp_com::params_map]]
    set iccpp_param_dict [array get ::iccpp_com::params_map]

    TclComplete::write_json $outdir/iccpp      [TclComplete::list_to_json $iccpp_param_list]
    TclComplete::write_json $outdir/iccpp_dict [TclComplete::dict_to_json $iccpp_param_dict] 
}

##########################################################################
# Write an aliases.vim file in Vimscript for extremely common ICC2 aliases
##########################################################################
proc TclComplete::write_aliases_vim {outdir} {
    #----------------------------------------------------
    # Write out aliases as Vim insert mode abbreviations
    #----------------------------------------------------
    set f   [open $outdir/aliases.vim w]
    puts $f "iabbrev fic foreach_in_collection"
    puts $f "iabbrev ga  get_attribute"
    puts $f "iabbrev cs  change_selection"
    puts $f "iabbrev gs  get_selection"

    close $f
    puts "...aliases.vim file complete."
}


###############################################################
# Write JSON files for rdt_steps (if RDT flow exists)
###############################################################
proc TclComplete::write_rdt_steps {outdir} {
    # RDT stages and steps in a dictionary.
    #  key = stage
    #  value = list of steps
    set rdt_steps [dict create]

    set rdt_stages [rdt_list_stages]
    foreach stage $rdt_stages {
        dict set rdt_steps $stage [rdt_list_steps $stage]
    }

    # Write out the JSON file.
    TclComplete::write_json $outdir/rdt_steps    [TclComplete::dict_of_lists_to_json $rdt_steps "no_sort"]
}
