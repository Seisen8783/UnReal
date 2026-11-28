//! CLI harness for verifying ACBridge over USB (Mac) or TCP loopback (with pairing file).

use std::ffi::{CStr, CString};
use std::ptr;

use ac_bridge::{
    ac_device_info, ac_device_info_get, ac_last_error, ac_location_clear, ac_location_open,
    ac_location_set, ac_session, ac_session_close, ac_session_open, ac_session_open_usb,
    ac_status,
};

fn last_err() -> String {
    unsafe { CStr::from_ptr(ac_last_error()) }
        .to_string_lossy()
        .into_owned()
}

fn check(label: &str, status: ac_status) {
    if status != ac_status::AC_OK {
        eprintln!("[{label}] failed ({status:?}): {}", last_err());
        std::process::exit(1);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage:");
        eprintln!("  ac_bridge_cli usb [udid] [set <lat> <lon> | clear | info]");
        eprintln!("  ac_bridge_cli tcp <ip> <pairing.plist> [set <lat> <lon> | clear | info]");
        std::process::exit(2);
    }

    let mut session: *mut ac_session = ptr::null_mut();
    let mut cmd_index = 2;

    match args[1].as_str() {
        "usb" => {
            let udid_arg = args.get(2).and_then(|s| {
                if matches!(s.as_str(), "set" | "clear" | "info") {
                    None
                } else {
                    cmd_index = 3;
                    Some(s.as_str())
                }
            });
            let c_udid = udid_arg.map(|u| CString::new(u).unwrap());
            let ptr_udid = c_udid.as_ref().map_or(ptr::null(), |u| u.as_ptr());
            check("open_usb", ac_session_open_usb(ptr_udid, 15_000, &mut session));
        }
        "tcp" => {
            if args.len() < 4 {
                eprintln!("tcp mode requires <ip> <pairing.plist>");
                std::process::exit(2);
            }
            let ip = CString::new(args[2].as_str()).unwrap();
            let pairing = std::fs::read(&args[3]).expect("failed to read pairing file");
            cmd_index = 4;
            check(
                "open_tcp",
                ac_session_open(ip.as_ptr(), 62078, pairing.as_ptr(), pairing.len(), 15_000, &mut session),
            );
        }
        other => {
            eprintln!("unknown mode: {other}");
            std::process::exit(2);
        }
    }

    let mut info = ac_device_info::default();
    check("device_info", ac_device_info_get(session, &mut info));
    let name = unsafe { CStr::from_ptr(info.device_name.as_ptr()) }.to_string_lossy();
    let version = unsafe { CStr::from_ptr(info.product_version.as_ptr()) }.to_string_lossy();
    println!(
        "Device: {name} | iOS {version} | developer_mode={} | ddi_mounted={}",
        info.developer_mode, info.ddi_mounted
    );

    if let Some(sub) = args.get(cmd_index).map(String::as_str) {
        match sub {
            "info" => {}
            "set" => {
                let lat: f64 = args[cmd_index + 1].parse().expect("invalid lat");
                let lon: f64 = args[cmd_index + 2].parse().expect("invalid lon");
                check("location_open", ac_location_open(session));
                check("location_set", ac_location_set(session, lat, lon));
                println!("Set location to {lat}, {lon}");
            }
            "clear" => {
                check("location_open", ac_location_open(session));
                check("location_clear", ac_location_clear(session));
                println!("Cleared simulated location");
            }
            other => {
                eprintln!("unknown command: {other}");
                ac_session_close(session);
                std::process::exit(2);
            }
        }
    }

    ac_session_close(session);
}
