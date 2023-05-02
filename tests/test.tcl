set dir [file normalize ../build]
source ../build/pkgIndex.tcl
package require tin
tin import mpjobs
tin import writeTable from tda
tin import assert from flytrap

# jobBoard (with -debug and -wipe)
# makeJob
# Initialize (with time-out)
catch {jobBoard -debug -wipe -timeout 00:00:05 CantileverStudy {
    foreach L {10 20 30} {
        foreach I {100 200 300} {
            makeJob Cantilever.tcl L $L I $I
        }
    }
}}

# getJobTags
# runJobs
jobBoard CantileverStudy {
    assert [getJobTags] eq [getJobTags -available]
    assert [getJobCount] == 9
    assert [lindex [getJobTags] 0] == 0
    runJobs
}

# Resume study
# resetJobs
# getJobResults
# getJobInputs
# getJobTable
# waitForJobs
jobBoard -debug CantileverStudy {
    # Re-run job
    set jobTag [makeJob Cantilever.tcl L 10 I 100]
    resetJobs $jobTag
    runJobs
    waitForJobs
    
    # Verify job input format
    set inputs [getJobInputs $jobTag]
    assert $inputs eq {folder .. filename Cantilever.tcl L 10 I 100}
    
    # Get displacement for L == 10 and I == 100
    set results [getJobResults $jobTag]
    assert [dict keys $results] eq {disp moment}
    assert [dict get $results disp] == 0.0011494252873563214
    assert [dict get $results moment] == -99.99999999999994
    # Get job table of results, and ensure that table is as expected.
    set jobTable [getJobTable]
    assert [$jobTable query {@L == 10 && @I == 100}] == $jobTag
    assert [$jobTable get $jobTag disp] == 0.0011494252873563214
    assert [$jobTable get $jobTag moment] == -99.99999999999994
    assert [$jobTable fields] eq {status folder filename L I disp moment}
    assert [$jobTable keys] eq [getJobTags]
    
    # Export table to csv
    writeTable CantileverStudy/results.csv $jobTable
    $jobTable destroy
}

# updateJobs; # Non-blocking update of active jobs
# waitForJobs; # Blocking update of active jobs
# getJobStatus; # Get status of async job
jobBoard -debug CantileverStudy {
    makeJob Cantilever.tcl L 40 I 100
    makeJob Cantilever.tcl L 41 I 100
    makeJob Cantilever.tcl L 42 I 100
    set errorJob [makeJob Cantilever.tcl L 42 I foo]; # Will result in error
    runJobs
    while {[getJobStatus $errorJob] == 1} {
        updateJobs $errorJob
        after 100; # incorporate a pause
    }
    assert [getJobStatus $errorJob] == 3; # Completed with error
}

# getJobCount
# getJobTags
# wipeJobs
jobBoard CantileverStudy {
    assert [getJobCount] == 13
    set jobTags ""
    for {set i 0} {$i < 13} {incr i} {
        lappend jobTags $i
    }
    assert [getJobTags] eq $jobTags
    wipeJobs
    assert [getJobCount] == 0
    assert [getJobTags] eq {}
    assert [[getJobTable]] eq {keyname jobTag fieldname field keys {} fields {status folder filename} data {}}
}

exit 1; # Return "ok" to caller