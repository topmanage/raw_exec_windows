// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

//go:build windows

package executor

import (
	"bytes"
	"fmt"
	"golang.org/x/sys/windows"
	"net/http"
	"os"
	"syscall"
	"time"
	"unsafe"
)

// configure new process group for child process
func (e *UniversalExecutor) setNewProcessGroup() error {
	// We need to check that as build flags includes windows for this file
	if e.childCmd.SysProcAttr == nil {
		e.childCmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	e.childCmd.SysProcAttr.CreationFlags = syscall.CREATE_NEW_PROCESS_GROUP
	return nil
}

// Cleanup any still hanging user processes
// func (e *UniversalExecutor) killProcessTree(proc *os.Process) error {
// 	// We must first verify if the process is still running.
// 	// (Windows process often lingered around after being reported as killed).
// 	handle, err := syscall.OpenProcess(syscall.PROCESS_TERMINATE|syscall.SYNCHRONIZE|syscall.PROCESS_QUERY_INFORMATION, false, uint32(proc.Pid))
// 	if err != nil {
// 		return os.NewSyscallError("OpenProcess", err)
// 	}
// 	defer syscall.CloseHandle(handle)

// 	result, err := syscall.WaitForSingleObject(syscall.Handle(handle), 0)

//		switch result {
//		case syscall.WAIT_OBJECT_0:
//			return nil
//		case syscall.WAIT_TIMEOUT:
//			// Process still running.  Just kill it.
//			return proc.Kill()
//		default:
//			return os.NewSyscallError("WaitForSingleObject", err)
//		}
//	}
//

// Function to recursively get all child process IDs
func getChildProcessesRecursive(parentPid int) ([]int, error) {
	var allChildPids []int

	// Create a snapshot of all processes
	handle, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer windows.CloseHandle(handle)

	var processEntry windows.ProcessEntry32
	processEntry.Size = uint32(unsafe.Sizeof(processEntry))

	// Iterate through the processes
	if err = windows.Process32First(handle, &processEntry); err != nil {
		return nil, err
	}

	for {
		if int(processEntry.ParentProcessID) == parentPid {
			childPid := int(processEntry.ProcessID)
			// Add the child PID to the list
			allChildPids = append(allChildPids, childPid)

			// Recursively get child processes of this child
			childDescendants, err := getChildProcessesRecursive(childPid)
			if err != nil {
				return nil, err
			}
			// Add all descendants to the list
			allChildPids = append(allChildPids, childDescendants...)
		}
		if err = windows.Process32Next(handle, &processEntry); err != nil {
			if err == windows.ERROR_NO_MORE_FILES {
				break
			}
			return nil, err
		}
	}

	return allChildPids, nil
}

// Function to kill a process by its PID
func killProcess(pid int) error {
	// Open the process with termination rights
	handle, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return err
	}
	defer windows.CloseHandle(handle)

	// Terminate the process
	err = windows.TerminateProcess(handle, 0)
	if err != nil {
		return err
	}

	return nil
}

func (e *UniversalExecutor) killProcessTree(proc *os.Process) error {
	// Get all child process IDs (including descendants)
	childPids, err := getChildProcessesRecursive(proc.Pid)
	if err != nil {
		e.logger.Warn("Error gettings child processes: %v", err)
	}

	// Kill each process and ignore any errors
	for _, pid := range childPids {
		err := killProcess(pid)
		if err != nil {
			e.logger.Warn("Error killing process: %v", err)
		}
	}

	err = killProcess(proc.Pid)
	if err != nil {
		e.logger.Warn("Error killing process: %v", err)
	}
	return nil
}

// Send the process a Ctrl-Break event, allowing it to shutdown by itself
// before being Terminate.
func (e *UniversalExecutor) shutdownProcess(s os.Signal, proc *os.Process) error {
	if s == nil {
		s = os.Kill
	}
	if s.String() == os.Interrupt.String() {
		if err := sendCtrlBreak(proc.Pid); err != nil {
			return fmt.Errorf("executor shutdown error: %v", err)
		}
		if err := e.sendShutdown(proc); err != nil {
			return err
		}
	} else {
		if err := sendCtrlBreak(proc.Pid); err != nil {
			return fmt.Errorf("executor shutdown error: %v", err)
		}
	}

	return nil
}

func (e *UniversalExecutor) sendShutdown(proc *os.Process) error {
	url := "http://127.0.0.1:9977/shutdown"
	method := "POST"
	payload := []byte{}
	client := &http.Client{
		Timeout: time.Second * 5,
	}
	req, _ := http.NewRequest(method, url, bytes.NewBuffer(payload))

	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("Error making request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("Error returned non 200 code: %v", err)
	}
	return nil
}

// Send a Ctrl-C signal for shutting down the process,
func sendCtrlC(pid int) error {
	err := windows.GenerateConsoleCtrlEvent(syscall.CTRL_C_EVENT, uint32(pid))
	if err != nil {
		return fmt.Errorf("Error sending ctrl-c event: %v", err)
	}
	return nil
}

// Send a Ctrl-Break signal for shutting down the process,
func sendCtrlBreak(pid int) error {
	err := windows.GenerateConsoleCtrlEvent(syscall.CTRL_BREAK_EVENT, uint32(pid))
	if err != nil {
		return fmt.Errorf("Error sending ctrl-break event: %v", err)
	}
	return nil
}
