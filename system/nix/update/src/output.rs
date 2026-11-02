//! The update path's recorded output contract, read by cloud's nudge and the tests, RFC cbtjl.

use std::fmt;
use std::io::Write;

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
	/// `/boot` being frozen and thawed, which puts its journal in place.
	RestingBoot,
	/// `/boot` frozen and thawed.
	BootRested,
	/// `/boot` is no mount of its own, so nothing was frozen.
	BootNotMounted,
	/// `/boot`'s filesystem cannot be frozen, as vfat, so it is synced instead.
	BootUnsupported,
	/// `/boot` synced, which puts a filesystem with no journal in place.
	BootSynced,
	/// Syncing `/boot` failed.
	BootSyncFailed,
	/// Freezing `/boot` failed.
	BootFreezeFailed,
	/// Thawing `/boot` failed, so it may stay frozen.
	BootThawFailed,
	/// The system switch done.
	SwitchSucceeded,
	/// The driver pointer being read from the bucket.
	FetchingDriverPointer,
	/// The bucket holds no driver pointer or no signature for it.
	NoDriverPointer,
	/// The bucket holds no system pointer or no signature for it, as after either expired.
	NoSystemPointer,
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
	/// The version being replaced writing what stands.
	TakingSnapshot,
	/// A first install, which has no version to judge it against.
	FirstInstall,
	/// A running version with no snapshot command, as 0.1.3 and before.
	NoSnapshotCommand,
	/// A running version whose snapshot failed.
	SnapshotFailed,
	/// The version just restarted judging itself.
	CheckingDriver,
	/// A failed check going back to the driver before it.
	CheckFailed,
	/// The new version judged healthy.
	CheckPassed,
	/// An older version with no check command kept on level 1 alone.
	OlderKept,
	/// The new version let through with deployments that stood before it never compared.
	CheckPassedUncompared,
}

impl Step {
	/// The step's words, behind a second reference so one atomic pointer can hold them.
	fn text(self) -> &'static &'static str {
		match self {
			Self::ReadingAccess => &"reading runtime access files",
			Self::Recorded => &"accepted pointer recorded",
			Self::FetchingSystemPointer => &"fetching system pointer",
			Self::FetchingSignature => &"fetching pointer signature",
			Self::VerifyingSystemSignature => &"verifying system pointer signature",
			Self::ValidatingSystemPointer => &"validating system pointer",
			Self::AlreadyTaken => &"pointer already taken",
			Self::ReadingRunningSystem => &"reading the running system",
			Self::RunningSystem => &"pointer is the running system",
			Self::DiffersFromRunning => &"pointer differs from the running system",
			Self::WouldNotSwitchAgain => &"accepted pointer would not switch again",
			Self::WouldSwitch => &"dry run would switch to pointer system",
			Self::Realising => &"realising system without builds",
			Self::SettingProfile => &"setting system profile",
			Self::Switching => &"switching system",
			Self::RestoringSystem => &"switch failed, restoring previous system",
			Self::RestingBoot => &"resting /boot, freezing and thawing it",
			Self::BootRested => &"/boot rested",
			Self::BootNotMounted => &"/boot is not a mount of its own, so it cannot be brought to rest",
			Self::BootUnsupported => &"/boot's filesystem cannot be frozen, syncing it instead",
			Self::BootSynced => &"/boot synced",
			Self::BootSyncFailed => &"syncing /boot failed",
			Self::BootFreezeFailed => &"freezing /boot failed",
			Self::BootThawFailed => &"warning, thawing /boot failed, it may stay frozen",
			Self::SwitchSucceeded => &"system switch succeeded",
			Self::FetchingDriverPointer => &"fetching driver pointer",
			Self::NoDriverPointer => &"no driver pointer, nothing to do",
			Self::NoSystemPointer => &"no system pointer, nothing to do",
			Self::VerifyingDriverSignature => &"verifying driver pointer signature",
			Self::ValidatingDriverPointer => &"validating driver pointer",
			Self::ReadingRunningDriver => &"reading the running driver",
			Self::RunningDriver => &"pointer is the running driver",
			Self::WouldInstall => &"dry run would install pointer driver",
			Self::DownloadingArchive => &"downloading driver archive",
			Self::CheckingArchive => &"checking driver archive SHA-256",
			Self::UnpackingArchive => &"unpacking driver archive",
			Self::SwitchingLinks => &"switching driver links",
			Self::RestartingDriver => &"restarting driver services",
			Self::RestoringDriver => &"restart failed, restoring previous driver",
			Self::RemovingOlder => &"removing older driver versions",
			Self::InstallSucceeded => &"driver install succeeded",
			Self::TakingSnapshot => &"taking driver snapshot",
			Self::FirstInstall => &"first driver install, level 3 skipped",
			Self::NoSnapshotCommand => {
				&"warning, running driver has no snapshot command, no baseline, level 3 skipped"
			}
			Self::SnapshotFailed => &"warning, driver snapshot failed, no baseline, level 3 skipped",
			Self::CheckingDriver => &"checking driver health",
			Self::CheckFailed => &"check failed, restoring previous driver",
			Self::CheckPassed => &"driver check passed",
			Self::OlderKept => {
				&"warning, older driver has no check command, level 1 alone, levels 2 and 3 could not run"
			}
			Self::CheckPassedUncompared => {
				&"warning, driver check passed on levels 1 and 2 alone, deployments not compared"
			}
		}
	}
}

impl fmt::Display for Step {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(self.text())
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
	/// The switch succeeded but `/boot` was not brought to rest, so the pointer stays unrecorded and
	/// the next run switches again.
	#[error("switched, but /boot not at rest, pointer not recorded")]
	BootUnrested,
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
	/// The check failed and so did restoring the driver before it.
	#[error("check failed and driver restoration failed")]
	DriverCheckRestore,
	/// The check failed and the driver before it runs again, or none where none did.
	#[error("driver check failed")]
	DriverCheck,
}

/// Prints a step on standard output.
pub fn say(step: Step) {
	Output::new(&mut std::io::stdout(), &mut std::io::stderr()).say(step);
}

/// Prints a refusal on standard error.
pub fn refuse(refusal: Refusal) {
	Output::new(&mut std::io::stdout(), &mut std::io::stderr()).refuse(refusal);
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

impl Secrets {
	/// A line with the host, key and secret replaced by their placeholders.
	pub fn mask(&self, line: &str) -> String {
		let mut line = line.to_owned();
		for (value, replacement) in
			[(&self.host, "<endpoint>"), (&self.key, "<key>"), (&self.secret, "<secret>")]
		{
			if !value.is_empty() {
				line = line.replace(value, replacement);
			}
		}
		line
	}
}

/// Prints the last five diagnostic lines on standard error with the update prefix.
/// The host, key and secret are masked as literal text.
pub fn masked(lines: &str, secrets: &Secrets) {
	Output::new(&mut std::io::stdout(), &mut std::io::stderr()).masked(lines, secrets);
}

/// The run's standard output and error, replaced by writers in tests.
pub struct Output<'a> {
	out: &'a mut dyn Write,
	err: &'a mut dyn Write,
}

impl<'a> Output<'a> {
	/// Writes through the given standard output and error.
	pub fn new(out: &'a mut dyn Write, err: &'a mut dyn Write) -> Self {
		Self { out, err }
	}

	/// Prints a step on standard output.
	pub fn say(&mut self, step: Step) {
		machine_update_abort::note(step.text());
		let _ = writeln!(self.out, "update: {step}");
	}

	/// Prints a refusal on standard error.
	pub fn refuse(&mut self, refusal: Refusal) {
		self.error(&format!("update: refused, {refusal}"));
	}

	/// Prints one unprefixed line on standard output.
	pub fn line(&mut self, line: &str) {
		let _ = writeln!(self.out, "{line}");
	}

	/// Prints one unprefixed line on standard error.
	pub fn error(&mut self, line: &str) {
		let _ = writeln!(self.err, "{line}");
	}

	/// Prints the last five diagnostic lines with runtime access values masked.
	pub fn masked(&mut self, lines: &str, secrets: &Secrets) {
		let all: Vec<&str> = lines.lines().collect();
		for line in all.iter().skip(all.len().saturating_sub(5)) {
			self.error(&format!("update: {}", secrets.mask(line)));
		}
	}
}
