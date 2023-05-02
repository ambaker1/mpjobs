# mpjobs.tcl
################################################################################
# Parallel parametric job framework for OpenSees

# Copyright (C) 2023 Alex Baker, ambaker1@mtu.edu
# All rights reserved. 

# See the file "LICENSE" in the top level directory for information on usage, 
# redistribution, and for a DISCLAIMER OF ALL WARRANTIES.
################################################################################

package require tda::tbl 0.1; # for getJobTable

# Define namespace
namespace eval ::mpjobs {
    variable inScope 0; # Used to ensure commands are within jobBoard body
    variable debugMode false; # Whether to print debug statements
    variable maxTime Inf; # Maximum clock seconds time value for session
    variable stopped 0; # Whether the job board session has been stopped
    variable execArgs [list [file dirname [info nameofexecutable]]/OpenSees]
    variable jobData ""; # Dictionary of job data
    # jobTag:
    #   inputs:     inputDir, inputFile, inputVars
    #   status:     Job status (options listed below:)
    #       0:          Exists, not running
    #       1:          Running
    #       2:          Complete, no error
    #       3:          Complete, with error
    #   results:    Result or error dictionary
    variable inputMap ""; # Dictionary mapping inputs to jobTags
    variable job2pid ""; # Active jobTags to PIDs
    variable pid2job ""; # Inverse of job2pid. Active PIDs to jobTags
    variable jobQueue ""; # List of available jobs
    variable statusFID; # File ID for accessing status file
    variable inputsFID; # File ID for accessing inputs file
    
    # Main job board commands 
    namespace export jobBoard; # Main command
    namespace export makeJob; # Create a job with unique inputs
    namespace export runJobs; # Run jobs (either in series or in MPI)
    namespace export resetJobs; # Reset jobs to have status 0
    namespace export wipeJobs; # Clear entire job board
    namespace export updateJobs; # Non-blocking update of active jobs
    namespace export waitForJobs; # Blocking update of active jobs
    
    # Job board query commands
    # These query directly from internal data structures, with the exception of
    # getJobResults, which lazy loads from files.
    namespace export getJobTags; # Get job tags, optionally with specific status
    namespace export getJobCount; # Get total number of jobs
    namespace export getJobInputs; # Get inputs corresponding to job tag
    namespace export getJobStatus; # Get integer status code for job
    namespace export getJobResults; # Get results corresponding to job tag
    namespace export getJobTable; # Get table of results for specific job tags
}

# jobBoard --
#
# Main command, all other commands must be called in body of jobBoard.
#
# Syntax:
# jobBoard <-wipe> <-debug> <-timeout $time> $path $body
#
# Arguments:
# -wipe:    Option to wipe job board
# -debug:   Option to print out information about jobs
# time      Option to timeout (format HH:MM:SS)
# path:     Folder path where to store job data
# body:     Body to evaluate by coordinator thread

proc ::mpjobs::jobBoard {args} {
    variable statusFID
    variable inputsFID
    variable jobBoard
    variable jobData
    variable jobQueue
    variable inputMap
    variable job2pid
    variable pid2job
    variable inScope
    variable debugMode
    variable maxTime
    variable stopped
    if {[getPID] == 0} {
        # Coordinator (PID 0) 
        # --------------------------------------------------------------
        set inScope true; # Enables all other commands
        
        # Parse input
        if {[llength $args] < 2} {
            return -code error "Insufficient number of arguments"
        }
        set optionArgs [lrange $args 0 end-2]
        set path [lindex $args end-1]
        set body [lindex $args end]
        
        # Parse option arguments
        set wipe false
        set debugMode false
        set maxTime Inf
        set i 0
        while {$i < [llength $optionArgs]} {
            set option [lindex $optionArgs $i]
            switch $option {
                -wipe { # Wipe the job board
                    set wipe true
                }
                -debug { # Print out monitoring statements
                    set debugMode true
                }
                -timeout { # User specified maximum duration for job
                    set duration [lindex $optionArgs $i+1]
                    set maxTime [expr {[clock seconds] + 
                            [clock scan $duration -base 0 -format %T -gmt 1]}]
                    incr i
                }
                default {return -code error "Unknown option \"$option\""}
            }
            incr i
        }
        
        # Initialize folder structure and main data files
        set jobBoard [file normalize $path] 
        file mkdir $jobBoard
        # Try to occupy session file (checks if job board is occupied)
        if {[catch {file delete $jobBoard/SESSION}]} {
            return -code error "Job board open in another instance"
        }
        DebugPuts "Opening job board"
        set session [open $jobBoard/SESSION w]
        puts -nonewline $session [pid]; # system process ID (not getPID)
        flush $session
        # Send job board to worker processes
        if {[getNP] > 0} {
            send $jobBoard
        }
        # Open save-state files, creating if they do not exist
        set inputsFID [open $jobBoard/INPUTS {RDWR CREAT}]
        set statusFID [open $jobBoard/STATUS {RDWR CREAT}]
        # Handle -wipe option
        if {$wipe} {
            wipeJobs
        }
        # Read in data, and check for error
        set inputsList [read $inputsFID]
        set statusList [split [read $statusFID] {}]
        if {![string is list $inputsList]} {
            return -code error \
                    "error reading INPUTS file - not a valid list"
        }
        if {[llength $inputsList] != [llength $statusList]} {
            return -code error \
                    "incompatible INPUTS and STATUS files"
        }
        # Initialize data structures
        set jobTag 0; # Counter for initialization
        set jobData ""; # Dictionary of inputs, status, and results
        set inputMap ""; # Mapping of job inputs to job tags
        set jobQueue ""; # List of available jobs (status == 0)
        set job2pid ""; # Active job tag to PID
        set pid2job ""; # PID to active job tag
        foreach inputs $inputsList status $statusList {
            dict set jobData $jobTag inputs $inputs
            if {$status == 1} {
                set status 0; # Reset aborted jobs
                seek $statusFID $jobTag
                puts -nonewline $statusFID $status
            }
            if {$status == 0} {
                lappend jobQueue $jobTag
            }
            dict set jobData $jobTag status $status
            dict set inputMap $inputs $jobTag; # For O(1) lookup
            incr jobTag
        }
        flush $statusFID
        # Configure stdin to accept input (stop) (see runJobs)
        set stopped 0
        set stdinConfig [fconfigure stdin]
        fconfigure stdin -blocking 0 -buffering line
        # Evaluate coordinator body (catch everything)
        DebugPuts "Running job board script"
        catch {uplevel 1 $body} result options
        # Restore stdin configuration
        fconfigure stdin {*}$stdinConfig
        DebugPuts "Closing job board"
        # Close workers
        if {[getNP] > 0} {
            # Send signal to close
            for {set i 1} {$i < [getNP]} {incr i} {
                send -pid [GetWorker] CLOSE
            }
            barrier
        }
        # Close save-state files and session
        close $inputsFID
        close $statusFID
        close $session
        # Restore scope and pass results of body to caller
        set inScope false
        DebugPuts "Job board closed"
        return -options $options $result
    } else {
        # Worker (PID 1 to NP-1) 
        # --------------------------------------------------------------
        # Get job board and send process ID to coordinator
        recv jobBoard
        send -pid 0 [getPID]
        # Enter worker loop
        while {1} {
            recv -pid 0 message
            switch [lindex $message 0] {
                JOB {RunJob [lindex $message 1]}
                RESET {}
                CLOSE {break}
                default {return -code error "Unknown message"}
            }
            send -pid 0 [getPID]
        }; # end while 1
        barrier
    }
    
    return
}

# DebugPuts --
#
# Print to screen if -debug is on, with time-stamp
#
# Syntax:
# DebugPuts $message
#
# Arguments:
# message       Message to put to screen

proc ::mpjobs::DebugPuts {message} {
    variable debugMode
    if {$debugMode} {
        set timeStamp [clock format [clock seconds] -format %T]
        puts "\[$timeStamp\]: $message"
    }
}

# CheckExit --
#
# Check if the user exited the analysis or the time limit was reached.
# Throws error, which is caught by the main jobBoard process and passed to
# caller after all existing jobs are complete.
#
# User can break out of loop with "stop"

proc ::mpjobs::CheckExit {} {
    variable maxTime
    # Check if user inputted "stop"
    if {[gets stdin command] != -1} {
        if {$command eq "stop"} {
            DebugPuts "User-controlled stop, finishing"
            return -code error "Job board stopped by user"
        }
    }
    # Check timeout
    if {[clock seconds] >= $maxTime} {
        DebugPuts "Time limit reached, finishing"
        return -code error "Job board timed out"
    }
}

# wipeJobs --
#
# Clear all data and files for job board. 
# Cannot specify certain jobs. Must wipe all.

proc ::mpjobs::wipeJobs {} {
    ValidateScope
    variable jobBoard
    variable jobData
    variable jobQueue
    variable inputMap
    variable inputsFID
    variable statusFID
    DebugPuts "Wiping job board"
    # Ensure that no jobs are active (clears job2pid and pid2job)
    waitForJobs
    # Delete all job files
    file delete {*}[glob -nocomplain -directory $jobBoard *.dat]
    file delete {*}[glob -nocomplain -directory $jobBoard *.log]
    file delete {*}[glob -nocomplain -directory $jobBoard *.tcl]
    # Truncate save-state files
    chan truncate $inputsFID 0
    chan truncate $statusFID 0
    # Wipe data structures
    set jobData ""
    set jobQueue ""
    set inputMap ""
    return
}

# resetJobs --
#
# Reset jobs with non-zero status to status 0
# This removes all results, but does not remove the jobs.
#
# Syntax:
# resetJobs <$jobTags>
#
# Arguments:
# jobTags:      Job tags to reset. Default -all 

proc ::mpjobs::resetJobs {{jobTags -all}} {
    ValidateScope
    variable jobBoard
    variable jobData
    variable jobQueue
    variable statusFID
    # Ensure that specified jobs are not active
    waitForJobs $jobTags
    # Process job tags option
    if {$jobTags eq "-all"} {
        set jobTags [dict keys $jobData]
    } else {
        ValidateJobTags $jobTags
    }
    foreach jobTag $jobTags {
        # Only reset if the status is not zero.
        if {[dict get $jobData $jobTag status] == 0} {
            continue
        }
        DebugPuts "Resetting job $jobTag"
        # Reset files
        seek $statusFID $jobTag
        puts -nonewline $statusFID 0
        file delete $jobBoard/$jobTag.dat 
        file delete $jobBoard/$jobTag.log
        file delete $jobBoard/$jobTag.tcl
        # Reset data structures
        dict unset jobData $jobTag results
        dict set jobData $jobTag status 0
        lappend jobQueue $jobTag
    }
    flush $statusFID
    return
}

# makeJob --
# 
# Create a unique job in job board.
# If the job already exists, simply return the corresponding jobTag.
#
# Syntax:
# makeJob <$inputDir> <$inputFile> $varName $value ...
# 
# Arguments:
# inputDir:     Input directory for job (absolute or relative to job board).
#                   Default .. (one folder up from job board)
# inputFile:    Input file for job (relative to inputDir)
# args:         Input arguments (key - value pairing of inputs)

proc ::mpjobs::makeJob {args} {
    ValidateScope
    variable jobBoard
    variable jobData
    variable jobQueue
    variable inputMap
    variable inputsFID
    variable statusFID
    
    # Switch input type for even/odd inputs
    if {[llength $args]%2 == 1} {
        set inputDir ..
        set inputVars [lassign $args inputFile]
    } else {
        set inputVars [lassign $args inputDir inputFile]
    }
    # Remove reserved fields
    set inputVars [dict remove $inputVars jobTag status folder filename]
    set inputs [list $inputDir $inputFile $inputVars]
    
    # See if job exists (return existing job tag)
    if {[dict exists $inputMap $inputs]} {
        return [dict get $inputMap $inputs]
    }
    
    # Get unique job tag
    set jobTag [dict size $jobData]
    DebugPuts "Creating job $jobTag"
    
    # Add job to files 
    puts $inputsFID [list $inputs]
    flush $inputsFID
    seek $statusFID $jobTag
    puts -nonewline $statusFID 0
    flush $statusFID
    
    # Add job to data structures
    dict set jobData $jobTag inputs $inputs
    dict set jobData $jobTag status 0    
    dict set inputMap $inputs $jobTag 
    lappend jobQueue $jobTag
    
    # Return job tag to caller
    return $jobTag
}

# runJobs --
#
# Execute all jobs in queue
# If in parallel mode, may return with jobs still running.
#
# Syntax:
# runJobs <$jobTags>
#
# Arguments:
# jobTags:          Jobs to run. Default -all

proc ::mpjobs::runJobs {{jobTags -all}} {
    ValidateScope
    CheckExit
    variable jobBoard
    variable jobData
    variable jobQueue
    variable statusFID
    variable job2pid
    variable pid2job
    # Process job tags option
    if {$jobTags eq "-all"} {
        # Run all jobs in queue. Most efficient, this method is preferred.
        set jobTags $jobQueue
        set jobQueue ""
    } else {
        # User specified job tags. This is not as efficient
        ValidateJobTags $jobTags
        # Filter job tags to only be those that are available
        set jobTags [lmap jobTag $jobTags {expr {
            [dict get $jobData $jobTag status] == 0 ? $jobTag : [continue]
        }}]
        # Remove from queue
        foreach jobTag $jobTags {
            set i [lsearch -exact -integer $jobQueue $jobTag]
            set jobQueue [lreplace $jobQueue $i $i]
        }
    }
    
    # Update job statuses to "active" and generate job files
    foreach jobTag $jobTags {
        # Create job input file ($jobTag.tcl)
        lassign [dict get $jobData $jobTag inputs] inputDir inputFile inputVars
        set fid [open $jobBoard/$jobTag.tcl w]
        dict for {var value} $inputVars {
            puts $fid [list set $var $value]
        }
        puts $fid [list cd $inputDir]
        puts $fid [list source $inputFile]
        close $fid
        
        # Update status (running)
        dict set jobData $jobTag status 1
        seek $statusFID $jobTag
        puts -nonewline $statusFID 1
    }
    flush $statusFID
    
    # Run or assign all jobs
    foreach jobTag $jobTags {
        CheckExit
        # Switch for series/parallel
        if {[getNP] == 1} {
            # Run job in series
            DebugPuts "Running job $jobTag in current process"
            RunJob $jobTag
            # Get status from file
            seek $statusFID $jobTag
            set status [read $statusFID 1]
            dict set jobData $jobTag status $status
            DebugPuts "Job $jobTag completed with status $status"
        } else {
            # Send job to worker
            set pid [GetWorker]
            DebugPuts "Assigning job $jobTag to processor $pid"
            dict set pid2job $pid $jobTag
            dict set job2pid $jobTag $pid
            send -pid $pid [list JOB $jobTag]
        }
    }
    return
}

# GetWorker --
#
# Gets a worker, updating data structures if the worker was assigned to a job
#
# Syntax:
# GetWorker <$pid>
#
# Arguments:
# pid:      PID to get (default ANY)

proc ::mpjobs::GetWorker {{pid ANY}} {
    variable statusFID
    variable jobData
    variable pid2job
    variable job2pid
    recv -pid $pid pid
    if {[dict exists $pid2job $pid]} {
        set jobTag [dict get $pid2job $pid]
        seek $statusFID $jobTag
        set status [read $statusFID 1]
        dict set jobData $jobTag status $status
        dict unset pid2job $pid
        dict unset job2pid $jobTag
        DebugPuts "Job $jobTag completed with status $status"
    }
    return $pid
}

# RunJob --
#
# Private procedure that runs a single job in separate instance of OpenSees
# Can be called in series by main thread or in parallel by worker threads.
#
# Syntax:
# RunJob $jobTag
# 
# Arguments:
# jobTag:           Job to run

proc ::mpjobs::RunJob {jobTag} {
    variable jobBoard
    variable execArgs
    exec {*}$execArgs 2>$jobBoard/$jobTag.log <<[list apply {{jobBoard jobTag} {
        # Enter job board
        cd $jobBoard
        
        # Get file handles
        set statusFID [open STATUS r+]
        set resultFID [open $jobTag.dat w]

        # Run job file, catching any errors
        if {[catch {uplevel 1 [list source $jobTag.tcl]} result options] == 0} {
            # Return code 0. Write results to file.
            set status 2
            puts $resultFID $result
        } else {
            # Error or other exceptional return code. Write errorinfo to file.
            set status 3
            puts $resultFID $options
        }
        
        # Close the result file, then change the status code to signal that the 
        # results are available. This order is important to avoid race condition
        close $resultFID
        
        # Write status to file
        seek $statusFID $jobTag
        puts -nonewline $statusFID $status
        close $statusFID
        
        # Return options to caller (this throws errors to terminal as well)
        return -options $options $result
    }} $jobBoard $jobTag]
    return
}

# waitForJobs --
#
# Wait for active jobs, in a blocking way (in parallel mode)
#
# Syntax:
# waitForJobs <$jobTags>
#
# jobTags:      List of job tags, or -all for all active jobs. Default -all

proc ::mpjobs::waitForJobs {{jobTags -all}} {
    ValidateScope
    variable pid2job
    variable job2pid
    # Process job tags option
    if {$jobTags eq "-all"} {
        set jobTags [dict keys $job2pid]
    } else {
        # User specified job tags.
        ValidateJobTags $jobTags
        set jobTags [lmap jobTag $jobTags {expr {
            [dict exists $job2pid $jobTag] ? $jobTag : [continue]
        }}]
    }
    foreach jobTag $jobTags {
        # Get the worker assigned to the job, and reset it.
        send -pid [GetWorker [dict get $job2pid $jobTag]] RESET
    }
    return
}

# updateJobs --
# 
# Update the status of active jobs in a non-blocking way (in parallel mode)
# Returns blank.
#
# Syntax:
# updateJobs <$jobTags>
#
# Arguments:
# jobTags:      List of job tags, or -all for all active jobs. Default -all

proc ::mpjobs::updateJobs {{jobTags -all}} {
    ValidateScope
    variable statusFID
    variable jobData
    variable job2pid
    variable pid2job
    # Process job tags option
    if {$jobTags eq "-all"} {
        set jobTags [dict keys $job2pid]
    } else {
        # User specified job tags.
        ValidateJobTags $jobTags
        set jobTags [lmap jobTag $jobTags {expr {
            [dict exists $job2pid $jobTag] ? $jobTag : [continue]
        }}]
    }
    foreach jobTag $jobTags {
        # Check status
        seek $statusFID $jobTag
        set status [read $statusFID 1]
        if {$status != 1} {
            # Update status and remove from active job maps.
            dict set jobData $jobTag status $status
            dict unset pid2job [dict get $job2pid $jobTag]
            dict unset job2pid $jobTag
        }
    }
    return
}

# getJobTags --
#
# Get list of job tags.
# Designed more for introspection than actual use in running jobs.
#
# Syntax:
# getJobTags <$option>
#
# Arguments:
# option:       Option for type of jobs to return. Default -all.
#   -all:       All job tags
#   -available: Status code 0
#   -active:    Status code 1
#   -complete:  Status code 2
#   -failed:    Status code 3
#   $codes:     List of status codes to include

proc ::mpjobs::getJobTags {{option -all}} {
    ValidateScope
    variable jobData
    switch $option {
        -all { # Irrespective of status code
            return [dict keys $jobData]
        }
        -available { # Posted, not running
            set statusCodes 0
        }
        -active { # Currently running
            set statusCodes 1
        }
        -complete { # Completed successfully
            set statusCodes 2
        }
        -failed { # Completed, with error
            set statusCodes 3
        }
        default { # User inputted list of status codes
            set statusCodes $option
            foreach status $statusCodes {
                if {$status ni {0 1 2 3}} {
                    return -code error "unknown status code: \"$status\""
                }
            }
        }
    }
    # Filter by status code
    return [dict keys [dict filter $jobData script {jobTag data} {
        expr {[dict get $data status] in $statusCodes}
    }]]
}

# getJobCount --
#
# Get total number of jobs
#
# Syntax:
# getJobCount

proc ::mpjobs::getJobCount {} {
    ValidateScope
    variable jobData
    return [dict size $jobData]
}

# getJobInputs --
#
# Returns the inputs of a job in dictionary form
# Fields: folder, filename, and user-defined variables
#
# Syntax:
# getJobInputs $jobTag
#
# Arguments:
# jobTag:           Integer job tag

proc ::mpjobs::getJobInputs {jobTag} {
    ValidateScope
    variable jobData
    ValidateJobTags $jobTag
    lassign [dict get $jobData $jobTag inputs] inputDir inputFile inputVars
    return [dict create folder $inputDir filename $inputFile {*}$inputVars]
}

# getJobStatus --
#
# Returns the saved status of a job.
#
# Syntax:
# getJobStatus $jobTag
#
# Arguments:
# jobTag:           Integer job tag

proc ::mpjobs::getJobStatus {jobTag} {
    ValidateScope
    variable jobData
    ValidateJobTags $jobTag
    return [dict get $jobData $jobTag status]
}

# getJobResults --
#
# Get results from job, reading from .dat file if needed
# Returns blank if job is not complete.
# Returns options dictionary for error.
#
# Syntax:
# getJobResults $jobTag
#
# Arguments:
# jobTag:           Integer job tag

proc ::mpjobs::getJobResults {jobTag} {
    ValidateScope
    variable jobBoard
    variable jobData
    ValidateJobTags $jobTag
    if {[dict exists $jobData $jobTag results]} {
        return [dict get $jobData $jobTag results]
    } elseif {[dict get $jobData $jobTag status] > 1} {
        # Read results from file
        set fid [open $jobBoard/$jobTag.dat r]
        set results [read -nonewline $fid]
        close $fid
        # Save and return results
        dict set jobData $jobTag results $results
        return $results
    } else {
        return ""
    }
}

# getJobTable --
#
# Get a table with job data.
#
# Syntax:
# getJobTable <$jobTags>
#
# Arguments:
# jobTags:      List of integer job tags. Default -all

proc ::mpjobs::getJobTable {{jobTags -all}} {
    ValidateScope
    variable jobData
    # Generate table
    set jobTable [::tda::tbl new]
    $jobTable define keyname jobTag
    $jobTable define fields {status folder filename}
    # Process job tags option
    if {$jobTags eq {-all}} {
        set jobTags [dict keys $jobData]
    } else {
        ValidateJobTags $jobTags
    }
    foreach jobTag $jobTags {
        # Get status (and catch for DNE)
        $jobTable set $jobTag status [dict get $jobData $jobTag status]
        $jobTable set $jobTag {*}[getJobInputs $jobTag]
        # Get job results (using getJobResults, which lazy loads from file)
        $jobTable set $jobTag {*}[getJobResults $jobTag]
    }
    return $jobTable
}

# ValidateScope --
#
# Ensure that commands are called in the proper scope (within jobBoard body)
#
# Syntax:
# ValidateScope

proc ::mpjobs::ValidateScope {} {
    variable inScope
    if {!$inScope} {
        return -code error "Must call within body of \"jobBoard\""
    }
}

# ValidateJobTags --
#
# Private procedure to validate a job tag input from user
#
# Syntax:
# ValidateJobTags $jobTags
#
# Arguments:
# jobTags:      List of integer job tags

proc ::mpjobs::ValidateJobTags {jobTags} {
    variable jobData
    foreach jobTag $jobTags {
        if {![dict exists $jobData $jobTag]} {
            return -code error "invalid job tag"
        }
    }
}

# Finally, provide the package
package provide mpjobs 0.1
