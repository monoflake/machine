//! Every line the update path prints, word for word what its shell printed, RFC cbtjl, as cloud's
//! nudge and the tests read them.

use std::fmt;

/// A step's line on standard output, printed as `update: <step>`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
	/// The endpoint and credentials files being read.
	ReadingAccess,
	/// A pointer the run accepted written to its state.
	Recorded,
	/// The system pointer being read from the bucket.
	FetchingSystemPointer,
	/// Either pointer's signature being read from the bucket.
	FetchingSignature,
	/// The system pointer's signature being checked.
	VerifyingSystemSignature,
	/// The system pointer's fields being checked.
	ValidatingSystemPointer,
	/// The pointer equals the one already accepted.
	AlreadyTaken,
	/// `/run/current-system` being read.
	ReadingRunningSystem,
	/// The pointer names the running system.
	RunningSystem,
	/// The pointer names another system than the running one.
	DiffersFromRunning,
	/// A pointer once accepted is never switched to again.
	WouldNotSwitchAgain,
	/// A dry run stopping where it would switch.
	WouldSwitch,
	/// The pointer's closure being made valid, building nothing.
	Realising,
	/// The system profile being set.
	SettingProfile,
	/// The new system's `switch-to-configuration switch` running.
	Switching,
	/// A failed switch going back to the system before it.
	RestoringSystem,
	/// The system switch done.
	SwitchSucceeded,
	/// The driver pointer being read from the bucket.
	FetchingDriverPointer,
	/// The bucket holds no driver pointer or no signature for it.
	NoDriverPointer,
	/// The driver pointer's signature being checked.
	VerifyingDriverSignature,
	/// The driver pointer's fields being checked.
	ValidatingDriverPointer,
	/// `/var/lib/driver/current` being read.
	ReadingRunningDriver,
	/// The pointer names the running driver.
	RunningDriver,
	/// A dry run stopping where it would install.
	WouldInstall,
	/// The driver's archive being downloaded.
	DownloadingArchive,
	/// The archive's SHA-256 being checked.
	CheckingArchive,
	/// The archive being checked and unpacked.
	UnpackingArchive,
	/// `current` and `previous` being moved.
	SwitchingLinks,
	/// The driver's two services being restarted.
	RestartingDriver,
	/// A failed restart going back to the driver before it.
	RestoringDriver,
	/// Versions neither current nor previous being removed.
	RemovingOlder,
	/// The driver install done.
	InstallSucceeded,
}

impl fmt::Display for Step {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Self::ReadingAccess => "reading runtime access files",
			Self::Recorded => "accepted pointer recorded",
			Self::FetchingSystemPointer => "fetching system pointer",
			Self::FetchingSignature => "fetching pointer signature",
			Self::VerifyingSystemSignature => "verifying system pointer signature",
			Self::ValidatingSystemPointer => "validating system pointer",
			Self::AlreadyTaken => "pointer already taken",
			Self::ReadingRunningSystem => "reading the running system",
			Self::RunningSystem => "pointer is the running system",
			Self::DiffersFromRunning => "pointer differs from the running system",
			Self::WouldNotSwitchAgain => "accepted pointer would not switch again",
			Self::WouldSwitch => "dry run would switch to pointer system",
			Self::Realising => "realising system without builds",
			Self::SettingProfile => "setting system profile",
			Self::Switching => "switching system",
			Self::RestoringSystem => "switch failed, restoring previous system",
			Self::SwitchSucceeded => "system switch succeeded",
			Self::FetchingDriverPointer => "fetching driver pointer",
			Self::NoDriverPointer => "no driver pointer, nothing to do",
			Self::VerifyingDriverSignature => "verifying driver pointer signature",
			Self::ValidatingDriverPointer => "validating driver pointer",
			Self::ReadingRunningDriver => "reading the running driver",
			Self::RunningDriver => "pointer is the running driver",
			Self::WouldInstall => "dry run would install pointer driver",
			Self::DownloadingArchive => "downloading driver archive",
			Self::CheckingArchive => "checking driver archive SHA-256",
			Self::UnpackingArchive => "unpacking driver archive",
			Self::SwitchingLinks => "switching driver links",
			Self::RestartingDriver => "restarting driver services",
			Self::RestoringDriver => "restart failed, restoring previous driver",
			Self::RemovingOlder => "removing older driver versions",
			Self::InstallSucceeded => "driver install succeeded",
		})
	}
}

/// Why a run stopped, printed on standard error as `update: refused, <reason>`, the run exiting 1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Refusal {
	/// An argument other than `system`, `driver` and `--dry-run`.
	#[error("unsupported instance or argument")]
	Arguments,
	/// The endpoint file could not be read.
	#[error("endpoint file unavailable")]
	Endpoint,
	/// `AWS_SHARED_CREDENTIALS_FILE` names another file than the configuration's.
	#[error("credentials file path differs")]
	CredentialsPath,
	/// The `[systems]` profile lacks one key, repeats one, or holds an unexpected character.
	#[error("systems credentials malformed")]
	Credentials,
	/// The bucket's name is no S3 bucket name.
	#[error("bucket malformed")]
	Bucket,
	/// The endpoint is no HTTPS origin.
	#[error("endpoint malformed")]
	EndpointMalformed,
	/// The system pointer's signature is not CI's in `system-pointer`.
	#[error("invalid system-pointer signature")]
	SystemSignature,
	/// The driver pointer's signature is no allowed signer's in `driver-pointer`.
	#[error("invalid driver-pointer signature")]
	DriverSignature,
	/// The pointer could not be read, for any reason but its absence.
	#[error("pointer fetch failed")]
	PointerFetch,
	/// The signature could not be read, for any reason but its absence.
	#[error("signature fetch failed")]
	SignatureFetch,
	/// A system pointer's keys or types are not exactly `at`, `machine`, `path` and `run`.
	#[error("malformed pointer fields")]
	Fields,
	/// A driver pointer's keys, types or archives are not as its protocol has them.
	#[error("malformed driver pointer fields or archive")]
	DriverFields,
	/// The pointer names another machine.
	#[error("written for another machine")]
	Machine,
	/// The path is no store path.
	#[error("malformed path")]
	Path,
	/// The version is no plain release name.
	#[error("malformed version")]
	Version,
	/// The time is no real UTC second written as `YYYY-MM-DDTHH:MM:SSZ`.
	#[error("malformed time")]
	Time,
	/// The time is more than an hour past the machine's clock.
	#[error("more than one hour ahead of its clock")]
	Ahead,
	/// The run is empty or holds a control character.
	#[error("malformed run")]
	Run,
	/// A driver pointer names a bucket build where builds are not allowed.
	#[error("build archives not allowed on this machine")]
	Builds,
	/// The state's accepted pointer no longer validates.
	#[error("recorded state malformed")]
	State,
	/// The pointer is older than the accepted one.
	#[error("older at than accepted pointer")]
	Older,
	/// The pointer has the accepted one's time and another run.
	#[error("equal at from another run")]
	OtherRun,
	/// The accepted run's system pointer names another path now.
	#[error("accepted run changed path")]
	ChangedPath,
	/// The accepted run's driver pointer differs now.
	#[error("accepted run changed pointer")]
	ChangedPointer,
	/// `/run/current-system` could not be read.
	#[error("running system unavailable")]
	Running,
	/// The closure could not be made valid.
	#[error("realise failed")]
	Realise,
	/// The system profile could not be set.
	#[error("profile update failed")]
	Profile,
	/// The switch failed and so did setting the profile back.
	#[error("switch failed and profile restoration failed")]
	ProfileRestore,
	/// The switch failed and so did switching back.
	#[error("switch failed and system restoration failed")]
	SystemRestore,
	/// The switch failed and the system before it runs again.
	#[error("switch failed")]
	Switch,
	/// The driver instance runs where the driver channel is off.
	#[error("driver channel disabled")]
	DriverChannel,
	/// The archive could not be downloaded.
	#[error("archive download failed")]
	Download,
	/// The archive's SHA-256 is not the pointer's.
	#[error("archive SHA-256 differs")]
	ArchiveHash,
	/// The archive is no gzip tar.
	#[error("invalid archive")]
	Archive,
	/// The archive holds a member other than the binary and its two licenses.
	#[error("unexpected archive member")]
	ArchiveMember,
	/// The archive holds a link or a special file.
	#[error("archive contains links or special files")]
	ArchiveType,
	/// The archive holds no executable `driver-machine`.
	#[error("archive lacks executable driver-machine")]
	ArchiveBinary,
	/// The restart failed and so did restoring the driver before it.
	#[error("restart failed and driver restoration failed")]
	DriverRestore,
	/// The restart failed and the driver before it runs again, or none where none did.
	#[error("driver restart failed")]
	DriverRestart,
}

/// Prints a step on standard output.
pub fn say(step: Step) {
	println!("update: {step}");
}

/// Prints a refusal on standard error.
pub fn refuse(refusal: Refusal) {
	eprintln!("update: refused, {refusal}");
}

/// What `masked` takes out of a failed tool's lines, each replaced by its placeholder.
#[derive(Debug, Clone, Default)]
pub struct Secrets {
	/// The endpoint's host, `<endpoint>`.
	pub host: String,
	/// The access key's id, `<key>`.
	pub key: String,
	/// The access key's secret, `<secret>`.
	pub secret: String,
}

/// A failed tool's last five lines on standard error, each `update: <line>`, the host, key and
/// secret masked as literal text, as the shell's `masked` printed them.
pub fn masked(lines: &str, secrets: &Secrets) {
	let all: Vec<&str> = lines.lines().collect();
	let start = all.len().saturating_sub(5);
	for line in all.iter().skip(start) {
		let mut line = (*line).to_owned();
		if !secrets.host.is_empty() {
			line = line.replace(&secrets.host, "<endpoint>");
		}
		if !secrets.key.is_empty() {
			line = line.replace(&secrets.key, "<key>");
		}
		if !secrets.secret.is_empty() {
			line = line.replace(&secrets.secret, "<secret>");
		}
		eprintln!("update: {line}");
	}
}
