if {![package vsatisfies [package provide Tcl] 8.6]} {return}
package ifneeded mpjobs 0.1.3 [list source [file join $dir mpjobs.tcl]]
