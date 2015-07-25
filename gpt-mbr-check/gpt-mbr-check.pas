program gpt_mbr_check;

{$DEFINE NOWARNINGS}
{$MODE OBJFPC}

{
	Exit codes:
		0 – no issues with boot signs were found;
		1 – at least one issue (i.e. duplicate boot disk sign) was found;
		2 – an error has occurred.
}

uses BaseUnix;

const
	SysBlockDir	= '/sys/block/';
	DevDir		= '/dev/';

	{ ioctl() constants from Linux. }
	BLKSSZGET: cuint32	= $1268;
	BLKGETSIZE64: cuint32	= $80081272;

	{ Various constants. }
	MAX_SECTOR_SIZE			= 8192;
	MAX_GPT_PARTITION_ENTRY_SIZE	= 256;
	MAX_PARTITIONS			= 4096;	{ Per GPT disk. Only non-empty partition entries are counted. }

	GUID_NULL: TGUID = '{00000000-0000-0000-0000-000000000000}';


type
	TDisk = record
		Enabled: Boolean;	{ Is this block device accessible? When False, only the Path is defined. }
		Path: AnsiString;	{ Path to a block device. }
		SectorSize: cint32;	{ Sector size of a block device in bytes. }
		Size: cuint64;		{ Size of a block device in sectors. }
	end;
	PDisk = ^TDisk;

	TDiskData = record
		Disk: PDisk;			{ Pointer to a current TDisk record, nil if a disk was not enabled. }
		{ Anything below is valid when Disk is not nil. }
		ChecksumISO: cuint32;		{ NTOS kernel checksum for a possible ISO 9660 superblock. }
		IsMBR: Boolean;			{ Is MBR present? }
		{ Two fields below are valid when IsMBR is True. }
		SignatureMBR: cuint32;		{ 32-bit MBR signature }
		ChecksumMBR: cuint32;		{ NTOS kernel checksum for a MBR }
		IsGPT: Boolean;			{ Is GPT present? }
		{ Three fields below are valid when IsGPT is True. }
		DiskGUID: TGUID;		{ Unique GPT disk GUID. }
		UniqueGUIDCount: cuint32;	{ Number of non-empty GPT partition entries on a disk. }
						{ Unique GUIDs of all non-empty GPT partition entries on a disk. }
		UniqueGUIDs: array [0..MAX_PARTITIONS-1] of TGUID;
	end;
	PDiskData = ^TDiskData;

	TGPTPartition = record
		DiskPath: AnsiString;	{ Path to a disk. }
		GUID: TGUID;		{ Unique GUID of a partition on a disk. }
	end;
	PGPTPartition = ^TGPTPartition;

var
	Disks: array of TDisk;
	DiskCount, EnabledDiskCount: Integer;
	DisksData: array of TDiskData;
	GUID_arr: array of TGPTPartition;

{
	Print a message to stdout.
}
procedure Info(const Msg: AnsiString);
begin
	WriteLn(Msg);
end;

{
	Print a warning to stderr.
}
procedure Warn(const Msg: AnsiString);
begin
{$IFNDEF NOWARNINGS}
	WriteLn(StdErr, Msg);
{$ENDIF}
{$UNDEF NOWARNINGS}
end;

{
	Print an error to stderr and halt.
}
procedure Err(const ExitMsg: AnsiString);
begin

	WriteLn(StdErr, ExitMsg);
	Halt(2);
end;

{ 
	Check if a file name refers to a valid block device in "/dev/".
	Virtual block devices (DM, MD, loop) and RAM disks are ignored.
}
function IsValidDiskName(const FileName: AnsiString): Boolean;
var
	FileStat: Stat;
begin
	IsValidDiskName := False;

	if (Pos('dm-', FileName) = 1) or ((Pos('md', FileName) = 1) and (Length(FileName) >= 3) and (FileName[3] >= '0')
		and (FileName[3] <= '9')) or (Pos('loop', FileName) = 1) or (Pos('ram', FileName) = 1) then Exit;

	if fpStat(DevDir + FileName, FileStat) <> 0 then Warn('File ' + DevDir + FileName + ' does not exist!')
	else IsValidDiskName := (FileStat.st_mode and S_IFBLK) = S_IFBLK;
end;

{
	Fill a TDisk record within the Disks array.
}
procedure FillDiskMetadata(const DiskPath: AnsiString; const DiskNum: Integer);
var
	HWD: cint;
	DiskSectorSize: cint32;
	DiskSize: cuint64;
begin
	Disks[DiskNum].Enabled := False;
	Disks[DiskNum].Path := DiskPath;

	HWD := FpOpen(DiskPath, O_RdOnly);
	if HWD <> 0 then
	begin
		DiskSectorSize := 0;
		if (FpIOCtl(HWD, BLKSSZGET, @DiskSectorSize) <> 0) or (DiskSectorSize < 512) then
			Warn('Sector size of ' + DiskPath + ' is unavailable! Skipping the disk...')
		else
		begin
			if DiskSectorSize > MAX_SECTOR_SIZE then
			begin
				FpClose(HWD);
				Err('Sector size is too large on ' + DiskPath + '!');
			end;
			Disks[DiskNum].SectorSize := DiskSectorSize;
			DiskSize := 0;
			if (FpIOCtl(HWD, BLKGETSIZE64, @DiskSize) = 0) and (DiskSize > 1048576) then
			begin
				Disks[DiskNum].Size := DiskSize div DiskSectorSize;
				Disks[DiskNum].Enabled := True;
				Inc(EnabledDiskCount);
			end else Warn('Size of ' + DiskPath + ' is unavailable! Skipping the disk...');
		end;
		FpClose(HWD);
	end else Err('Cannot open the ' + DiskPath + ' disk!');
end;

{
	Enumerate physical disks in a system.
	Child block devices (e.g. disk partitions) are not visible here.
}
procedure EnumDisks;
var
	pDirRec: pDir;
	pDirListRec: PDirent;
	FileName: AnsiString;
begin
	DiskCount := 0;
	EnabledDiskCount := 0;
	pDirRec := FpOpendir(SysBlockDir);
	if pDirRec <> nil then
	begin
		pDirListRec := FpReaddir(pDirRec^);
		while pDirListRec <> nil do
		begin
			FileName := StrPas(pDirListRec^.d_name);
			if not ((FileName = '.') or (FileName = '..')) and IsValidDiskName(FileName) then
			begin
				Inc(DiskCount);
				SetLength(Disks, DiskCount);
				FillDiskMetadata(DevDir + FileName, DiskCount - 1);
			end;
			pDirListRec := FpReaddir(pDirRec^);
		end;
		FpClosedir(pDirRec^);
	end else Err('Cannot open the ' + SysBlockDir + ' directory!');
end;

{
	Check if a given GUID is PARTITION_ENTRY_UNUSED_GUID (= GUID_NULL).
}
function IsEmptyGUID(const GUID: TGUID): Boolean;
var
	i: Integer;
begin
	for i := 0 to 7 do
		if GUID.D4[i] <> 0 then
		begin
			IsEmptyGUID := False;
			Exit;
		end;
	IsEmptyGUID := (GUID.D1 = 0) and (GUID.D2 = 0) and (GUID.D3 = 0);
end;

{
	Check if two GUIDs are identical.
}
function AreIdenticalGUIDs(const GUID1, GUID2: TGUID): Boolean;
var
	i: Integer;
begin
	for i := 0 to 7 do
		if GUID1.D4[i] <> GUID2.D4[i] then
		begin
			AreIdenticalGUIDs := False;
			Exit;
		end;
	AreIdenticalGUIDs := (GUID1.D1 = GUID2.D1) and (GUID1.D2 = GUID2.D2) and (GUID1.D3 = GUID2.D3); 
end;

{
	Parse MBR and GPT on disks detected.
}
procedure GetDisksData;
var
	i: Integer;
	HWD: cint;
	CurrentSector: array [0..MAX_SECTOR_SIZE-1] of Byte; { Cannot use dynamic arrays here! }
	CurrentPartitionEntry: array [0..MAX_GPT_PARTITION_ENTRY_SIZE-1] of Byte;
	CurrentSectorLength: cuint32;
	GPTBackupLBA: cuint64;
	CurrentUniqueGUID: cuint32;

{
	Parse GPT header and partition entries.

	LookAtBackup specifies the mode of operation:
		0 – look at a primary GPT block (and store the location of a backup GPT block for mode 1);
		1 – look at a backup GPT block specified by a primary GPT block;
		2 – look at a backup GPT block at the end of a disk (this should be called after mode 1).

}
procedure ParseGPT(const LookAtBackup: Integer);
var
	StartingOffset, CurrentOffset, FinalOffset, GPTPartitionTableStartLBA: cuint64;
	j, GPTPartitionsCount, GPTPartitionEntrySize: cuint32;
	PartitionTypeGUID, UniquePartitionGUID: TGUID;
	isGPT, alreadyHave: Boolean;
begin
	GPTPartitionTableStartLBA := 0;
	GPTPartitionsCount := 0;
	GPTPartitionEntrySize := 0;
	isGPT := False;

	if (LookAtBackup = 0) then StartingOffset := CurrentSectorLength
	else if (LookAtBackup = 1) then
	begin
		if (GPTBackupLBA > 0) and ((Disks[i].Size - 1 < GPTBackupLBA)
			or (GPTBackupLBA <= 2048)) then
		begin
			Warn('Pointer to a backup GPT block is invalid on ' + Disks[i].Path + '!');
			Exit;
		end;

		if GPTBackupLBA = 0 then Exit;
		StartingOffset := CurrentSectorLength * GPTBackupLBA;
	end
	else if (LookAtBackup = 2) then
	begin
		if Disks[i].Size - 1 = GPTBackupLBA then
			Exit; { GPTBackupLBA points to the end of a disk, no need to go further. }
		StartingOffset := CurrentSectorLength * (Disks[i].Size - 1);
	end else Exit;

	if FpLSeek(HWD, StartingOffset, Seek_Set) = StartingOffset then
	begin
		if FpRead(HWD, CurrentSector, CurrentSectorLength) <> CurrentSectorLength then
		begin
			FpClose(HWD);
			Err('IO error when reading GPT header from ' + Disks[i].Path + '!');
		end;

		{ GPT signature: "EFI PART". }
		isGPT := (CurrentSector[0] = $45) and (CurrentSector[1] = $46) and
			(CurrentSector[2] = $49) and (CurrentSector[3] = $20) and
			(CurrentSector[4] = $50) and (CurrentSector[5] = $41) and
			(CurrentSector[6] = $52) and (CurrentSector[7] = $54);

		if isGPT then
		begin
			if not DisksData[i].IsGPT then DisksData[i].IsGPT := True;
			if (LookAtBackUp = 0) then Move(CurrentSector[32], GPTBackupLBA, 8);
			if IsEmptyGUID(DisksData[i].DiskGUID) then
				Move(CurrentSector[56], DisksData[i].DiskGUID, 16);
			Move(CurrentSector[72], GPTPartitionTableStartLBA, 8);
			Move(CurrentSector[80], GPTPartitionsCount, 4);
			Move(CurrentSector[84], GPTPartitionEntrySize, 4);
		end else Exit;

		if (GPTPartitionEntrySize < 128) or (GPTPartitionEntrySize > MAX_GPT_PARTITION_ENTRY_SIZE) then
		begin
			FpClose(HWD);
			Err('GPT partition entries on ' + Disks[i].Path + ' have unsupported size!');
		end;

		if (Disks[i].Size - 1 < GPTPartitionTableStartLBA) then
		begin
			Warn('Pointer to a partition table block (GPT) is invalid on ' + Disks[i].Path + '!');
			Exit;
		end;


		FinalOffset := CurrentSectorLength * GPTPartitionTableStartLBA
			+ GPTPartitionEntrySize * GPTPartitionsCount;
		CurrentOffset := CurrentSectorLength * GPTPartitionTableStartLBA;
		repeat
			if FpLSeek(HWD, CurrentOffset, Seek_Set) = CurrentOffset then
			begin
				Inc(CurrentOffset, GPTPartitionEntrySize);
				if FpRead(HWD, CurrentPartitionEntry, GPTPartitionEntrySize) = GPTPartitionEntrySize then
				begin
					Move(CurrentPartitionEntry[0], PartitionTypeGUID, 16);
					if not IsEmptyGUID(PartitionTypeGUID) then
					begin
						Move(CurrentPartitionEntry[16], UniquePartitionGUID, 16);
						alreadyHave := False;
						if CurrentUniqueGUID > 0 then
							for j := 0 to CurrentUniqueGUID - 1 do
							begin
								alreadyHave := AreIdenticalGUIDs(DisksData[i].UniqueGUIDs[j], UniquePartitionGUID);
								if alreadyHave then Break;
							end;
						if not alreadyHave then
						begin
							if CurrentUniqueGUID > MAX_PARTITIONS - 1 then
							begin
								FpClose(HWD);
								Err('Too many GPT partitions on ' + Disks[i].Path + '!');
							end;
							DisksData[i].UniqueGUIDs[CurrentUniqueGUID] := UniquePartitionGUID;
							Inc(CurrentUniqueGUID);
						end;
					end;
				end
				else
				begin
					FpClose(HWD);
					Err('IO error when reading GPT partition table from ' + Disks[i].Path + '!');
				end;
			end
			else
			begin
				FpClose(HWD);
				Err('IO error when reading GPT partition table from ' + Disks[i].Path + '!');
			end;
		until CurrentOffset = FinalOffset;
	end else 
	begin
		FpClose(HWD);
		Err('IO error when reading GPT header from ' + Disks[i].Path + '!');
	end;
end;

{
	Calculate the NTOS kernel checksum for a possible ISO 9660 superblock.
}
procedure ChecksumISO9660;
var
	ISO9660_superblock: array [0..511] of cuint32;
	cur: Integer;
	Checksum: cuint32;
begin
	Checksum := 0;
	if FpLSeek(HWD, $8000, Seek_Set) = $8000 then
	begin
		if FpRead(HWD, ISO9660_superblock, 2048) <> 2048 then
		begin
			FpClose(HWD);
			Err('IO error when reading ISO 9660 superblock from ' + Disks[i].Path + '!');
		end;

		for cur := 0 to 511 do Inc(Checksum, ISO9660_superblock[cur]);
		DisksData[i].ChecksumISO := Checksum;
	end else
	begin
		FpClose(HWD);
		Err('IO error when reading ISO 9660 superblock from ' + Disks[i].Path + '!');
	end;
end;

{
	Calculate the NTOS kernel checksum for MBR.
	Uses the CurrentSector variable.
}
procedure ChecksumMBR;
var
	MBR_arr: array [0..127] of cuint32;
	cur: Integer;
	Checksum: cuint32;
begin
	Move(CurrentSector, MBR_arr, 512);
	Checksum := 0;
	for cur := 0 to 127 do Inc(Checksum, MBR_arr[cur]);
	DisksData[i].ChecksumMBR := Checksum;
end;

begin
	SetLength(DisksData, DiskCount);
	for i := 0 to DiskCount - 1 do
	begin
		if not Disks[i].Enabled then
		begin
			DisksData[i].Disk := nil;
			Continue;
		end;

		DisksData[i].Disk := @Disks[i];
		CurrentSectorLength := Disks[i].SectorSize;
		CurrentUniqueGUID := 0;

		HWD := FpOpen(Disks[i].Path, O_RdOnly);
		if HWD <> 0 then
		begin
			ChecksumISO9660;

			{ MBR }
			if FpLSeek(HWD, 0, Seek_Set) = 0 then
			begin
				if FpRead(HWD, CurrentSector, CurrentSectorLength) <> CurrentSectorLength then
				begin
					FpClose(HWD);
					Err('IO error when reading MBR from ' + Disks[i].Path + '!');
				end;

				{ Boot signature: 0x55 0xAA. }
				DisksData[i].IsMBR := (CurrentSector[510] = $55) and (CurrentSector[511] = $AA);
				if DisksData[i].IsMBR then
				begin
					ChecksumMBR;
					Move(CurrentSector[440], DisksData[i].SignatureMBR, 4);
				end;
			end else 
			begin
				FpClose(HWD);
				Err('IO error when reading MBR from ' + Disks[i].Path + '!');
			end;

			{ GPT primary }
			DisksData[i].IsGPT := False;
			DisksData[i].DiskGUID := GUID_NULL;
			GPTBackupLBA := 0;
			ParseGPT(0);

			{ GPT backup }
			ParseGPT(1);
			ParseGPT(2);
			DisksData[i].UniqueGUIDCount := CurrentUniqueGUID;

			FpClose(HWD);
		end else Err('Cannot open the ' + Disks[i].Path + ' disk!');
	end;
end;

{
	Scan for duplicate boot disk signs.
}
function NoDuplicates: Boolean;
var
	i, j, totalGUIDs: cuint32;
	LengthDisksData: Integer;
begin
	NoDuplicates := True;
	LengthDisksData := Length(DisksData);
	if LengthDisksData <= 1 then Exit;

	{ Pass #1. }
	for i := 0 to LengthDisksData - 1 do
	begin
		if DisksData[i].Disk = nil then Continue;

		{ Are there any duplicate MBR signatures? We ignore null signatures here. }
		if DisksData[i].IsMBR and (DisksData[i].SignatureMBR > 0) then
			for j := i + 1 to LengthDisksData - 1 do
				if (DisksData[j].Disk <> nil) and (DisksData[j].IsMBR) and
					(DisksData[i].SignatureMBR = DisksData[j].SignatureMBR) then
				begin
					Info('Identical MBR signatures found on ' + 
						DisksData[i].Disk^.Path + ' and ' + DisksData[j].Disk^.Path + '!');
					NoDuplicates := False;
					{ Do not stop here. }
				end;

		{ Are there any duplicate "unique" GPT disk GUIDs? }
		if DisksData[i].IsGPT then
			for j := i + 1 to LengthDisksData - 1 do
				if (DisksData[j].Disk <> nil) and (DisksData[j].IsGPT) and
					AreIdenticalGUIDs(DisksData[i].DiskGUID, DisksData[j].DiskGUID) then
				begin
					Info('Identical GPT disk identifier found on ' + 
						DisksData[i].Disk^.Path + ' and ' + DisksData[j].Disk^.Path + '!');
					NoDuplicates := False;
					{ Do not stop here. }
				end;

		{ MBR checksums loop is missing on purpose. }

		{ Are there any nonunique checksums for possible ISO 9660 superblocks? }
		{ Checksums equal to zero are ignored. }
		if DisksData[i].ChecksumISO > 0 then
			for j := i + 1 to LengthDisksData - 1 do
				if (DisksData[j].Disk <> nil) and
					(DisksData[i].ChecksumISO = DisksData[j].ChecksumISO) then
				begin
					Info('Equal checksums for ' + DisksData[i].Disk^.Path + 
						' (ISO 9660 checksum) and ' + DisksData[j].Disk^.Path +
						' (ISO 9660 checksum)!');
					NoDuplicates := False;
					{ Do not stop here. }
				end;

		{ Compare MBR checksums with checksums for possible ISO 9660 superblocks too. }
		{ Checksums equal to zero are ignored. }
		if DisksData[i].IsMBR and (DisksData[i].ChecksumMBR > 0) then
			for j := 0 to LengthDisksData - 1 do
				if (j <> i) and (DisksData[j].Disk <> nil) and
					(DisksData[i].ChecksumMBR = DisksData[j].ChecksumISO) then
				begin
					Info('Equal checksums for ' + DisksData[i].Disk^.Path + 
						' (MBR checksum) and ' + DisksData[j].Disk^.Path +
						' (ISO 9660 checksum)!');
					NoDuplicates := False;
					{ Do not stop here. }
				end;

		{ And vice versa. }
		if DisksData[i].ChecksumISO > 0 then
			for j := 0 to LengthDisksData - 1 do
				if (j <> i) and (DisksData[j].Disk <> nil) and (DisksData[j].IsMBR) and
					(DisksData[i].ChecksumISO = DisksData[j].ChecksumMBR) then
				begin
					Info('Equal checksums for ' + DisksData[i].Disk^.Path + 
						' (ISO 9660 checksum) and ' + DisksData[j].Disk^.Path +
						' (MBR checksum)!');
					NoDuplicates := False;
					{ Do not stop here. }
				end;
	end;

	{ Pass #2. }

	{ Copy all "unique" partition GUIDs into the single array. }
	totalGUIDs := 0;
	for i := 0 to LengthDisksData - 1 do
	begin
		if (DisksData[i].Disk = nil) or (not DisksData[i].IsGPT)
			or (DisksData[i].UniqueGUIDCount = 0) then Continue;

		for j := 0 to DisksData[i].UniqueGUIDCount - 1 do
		begin
			Inc(totalGUIDs);
			SetLength(GUID_arr, totalGUIDs);
			GUID_arr[totalGUIDs - 1].DiskPath := DisksData[i].Disk^.Path;
			GUID_arr[totalGUIDs - 1].GUID := DisksData[i].UniqueGUIDs[j];
		end;
	end;

	if not (totalGUIDs > 1) then Exit;
	

	{ Find duplicates. }
	for i := 0 to totalGUIDs - 1 do
	begin
		for j := i + 1 to totalGUIDs - 1 do
			if AreIdenticalGUIDs(GUID_arr[i].GUID, GUID_arr[j].GUID)
				and (GUID_arr[i].DiskPath <> GUID_arr[j].DiskPath) then
			begin
				Info('Duplicate "unique" partition GUID (GPT) found on ' +
					GUID_arr[i].DiskPath + ' and ' + GUID_arr[j].DiskPath + '!');
				NoDuplicates := False;
				{ Do not stop here. }
			end;
	end;
end;


begin
	EnumDisks;
	if DiskCount = 0 then Err('No disks found!');
	if EnabledDiskCount = 0 then Err('No accessible disks found!');
	GetDisksData;
	if NoDuplicates then
	begin
		Info('Everything looks good!');
		Halt(0);
	end else
	begin
		Info('At least one issue with boot signs was found!');
		Halt(1);
	end;
end.
