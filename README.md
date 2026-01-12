# SLYD Instance Scripts

These scripts are **NOT** part of the core library. They live in a separate GitHub repository and are downloaded by instances during cloud-init.

**Separate Repository:** `https://github.com/SLYD-Platform/instance-scripts`

## Files

- **VERSION** - Current script version for auto-update mechanism
- **slyd-r2-watcher.sh** - Main watcher script that monitors for download jobs
- **slyd-r2-watcher.service** - Systemd service configuration

## How It Works

### Installation (via cloud-init)
```bash
# Download script from GitHub
curl -fsSL https://raw.githubusercontent.com/SLYD-Platform/instance-scripts/main/slyd-r2-watcher.sh \
  -o /usr/local/bin/slyd-r2-watcher.sh
chmod +x /usr/local/bin/slyd-r2-watcher.sh

# Download and install systemd service
curl -fsSL https://raw.githubusercontent.com/SLYD-Platform/instance-scripts/main/slyd-r2-watcher.service \
  -o /etc/systemd/system/slyd-r2-watcher.service

# Enable and start service
systemctl daemon-reload
systemctl enable slyd-r2-watcher
systemctl start slyd-r2-watcher
```

### Usage (Platform Side)

```csharp
// 1. Upload file to R2, get presigned URL
var downloadUrl = await _r2Service.GetPresignedDownloadUrl(fileKey);

// 2. Create job file with download instructions
var jobConfig = new {
    url = downloadUrl,
    targetPath = "/home/ubuntu/uploads",
    filename = "myfile.txt",
    encrypted = true,
    encryptionKey = encryptionKey
};

// 3. Write job file to instance
await _lxdService.PutInstanceFile(
    lxdUri,
    instanceId.ToString(),
    $"/tmp/slyd-downloads/job-{Guid.NewGuid()}.json",
    JsonSerializer.Serialize(jobConfig)
);

// The watcher service automatically picks up and processes the job!
```

### Job File Format

```json
{
  "url": "https://r2.example.com/presigned-url",
  "targetPath": "/home/ubuntu/downloads",
  "filename": "document.pdf",
  "encrypted": true,
  "encryptionKey": "your-encryption-key"
}
```

**Fields:**
- `url` (required) - R2 presigned download URL
- `targetPath` (optional) - Target directory, defaults to `/home/ubuntu/downloads`
- `filename` (optional) - Final filename, defaults to extracted from URL
- `encrypted` (optional) - Whether file is encrypted, defaults to `false`
- `encryptionKey` (optional) - AES-256 decryption key if encrypted

### Auto-Update

The watcher checks GitHub hourly for updates:
1. Compares local version with `VERSION` file on GitHub
2. If newer version available, downloads new script
3. Replaces itself and restarts service
4. **Zero downtime** - happens automatically

## Resource Usage

- **CPU:** Limited to 5% via systemd
- **Memory:** Limited to 100MB via systemd
- **Disk:** Minimal (just script + logs)
- **Network:** Only active during downloads

## Monitoring

View logs:
```bash
# Real-time
journalctl -u slyd-r2-watcher -f

# Last 100 lines
journalctl -u slyd-r2-watcher -n 100

# Log file
tail -f /var/log/slyd-r2-watcher.log
```

Check status:
```bash
systemctl status slyd-r2-watcher
```

## Security Notes

- Script runs as root (needed for systemd operations)
- Encryption keys are passed in job files (temp files in `/tmp`)
- Job files are deleted after processing
- Uses OpenSSL AES-256-CBC for decryption
- Presigned URLs are short-lived (recommended: 15-60 minutes)

## Development

To update the scripts:
1. Make changes to files in separate `instance-scripts` repo
2. Update VERSION file
3. Push to GitHub
4. All instances will auto-update within 1 hour

## Deployment Checklist

- [ ] Create separate GitHub repo: `SLYD-Platform/instance-scripts`
- [ ] Push VERSION, slyd-r2-watcher.sh, slyd-r2-watcher.service
- [ ] Make repo public OR configure authentication for private repo
- [ ] Update cloud-init in LxdInstanceOperationService
- [ ] Test on a fresh instance
# instance-scripts
