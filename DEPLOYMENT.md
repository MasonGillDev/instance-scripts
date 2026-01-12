# R2 File Transfer System - Deployment Guide

## Overview

This system enables secure file transfers from your platform to LXD instances using Cloudflare R2 as the storage layer. It consists of:

1. **GitHub Repository** - Hosts the watcher scripts (auto-updates instances)
2. **LXD Instance Service** - Runs on every instance, watches for download jobs
3. **Platform Integration** - Core library methods to trigger downloads

## Step 1: Create GitHub Repository

Create a **separate public repository** (or private with auth):

**Repository:** `https://github.com/SLYD-Platform/instance-scripts`

**Upload these files:**
```
instance-scripts/
├── VERSION                     # Contains: 1.0.0
├── slyd-r2-watcher.sh         # Main watcher script
├── slyd-r2-watcher.service    # Systemd service
└── README.md                  # Documentation
```

All files are in: `/Users/masongill/Slyd-Platform/core/docs/instance-scripts/`

## Step 2: Update Core Library

The core library already has the integration! It's in:
- `LxdInstanceOperationService.cs:678-705` - `InstallR2FileWatcher()` method
- `LxdInstanceOperationService.cs:116` - Called in `PostLxdInstance()`
- `LxdInstanceOperationService.cs:504` - Called in `PostLxdInstanceGpu()`

**Update the GitHub URL if needed:**
```csharp
// Line 683 in LxdInstanceOperationService.cs
const string githubBase = "https://raw.githubusercontent.com/SLYD-Platform/instance-scripts/main";
```

Change `SLYD-Platform` to your organization name if different.

## Step 3: Platform Usage

### Basic File Transfer (platform-R2Test)

```csharp
using SLYD.Application.Interfaces.Infrastructure.Lxd;
using Microsoft.EntityFrameworkCore;

public class FileTransferController : ControllerBase
{
    private readonly ILxdInstanceOperationService _lxdService;
    private readonly IDbContextFactory<SlydDbContext> _dbContextFactory;
    private readonly ICloudflareR2Service _r2Service; // Your R2 service

    [HttpPost("upload/{instanceId}")]
    public async Task<IActionResult> UploadFileToInstance(
        Guid instanceId,
        IFormFile file,
        [FromQuery] bool encrypt = false)
    {
        // 1. Upload file to R2
        string fileKey = $"transfers/{instanceId}/{file.FileName}";

        if (encrypt)
        {
            // Encrypt file before uploading
            var encryptedStream = await EncryptFile(file.OpenReadStream());
            await _r2Service.UploadAsync(fileKey, encryptedStream);
        }
        else
        {
            await _r2Service.UploadAsync(fileKey, file.OpenReadStream());
        }

        // 2. Get presigned download URL (expires in 30 minutes)
        string downloadUrl = await _r2Service.GetPresignedDownloadUrlAsync(
            fileKey,
            TimeSpan.FromMinutes(30)
        );

        // 3. Get instance LXD URI
        using var dbContext = await _dbContextFactory.CreateDbContextAsync();
        var instance = await dbContext.Instances
            .Include(i => i.ProviderServer)
            .FirstOrDefaultAsync(i => i.Id == instanceId);

        if (instance?.ProviderServer?.LXDUri == null)
            return NotFound("Instance not found");

        // 4. Create download job
        var job = new
        {
            url = downloadUrl,
            targetPath = "/home/ubuntu/uploads",
            filename = file.FileName,
            encrypted = encrypt,
            encryptionKey = encrypt ? "your-encryption-key" : null
        };

        // 5. Write job file to instance
        string jobFile = $"/tmp/slyd-downloads/job-{Guid.NewGuid()}.json";
        bool success = await _lxdService.PutInstanceFile(
            instance.ProviderServer.LXDUri,
            instanceId.ToString(),
            jobFile,
            JsonSerializer.Serialize(job)
        );

        if (success)
        {
            return Ok(new
            {
                message = "File transfer initiated",
                targetPath = $"/home/ubuntu/uploads/{file.FileName}"
            });
        }

        return StatusCode(500, "Failed to initiate transfer");
    }
}
```

### Batch Transfer Multiple Files

```csharp
[HttpPost("upload-batch/{instanceId}")]
public async Task<IActionResult> UploadMultipleFiles(
    Guid instanceId,
    List<IFormFile> files)
{
    var results = new List<object>();

    foreach (var file in files)
    {
        // Upload to R2
        string fileKey = $"transfers/{instanceId}/{file.FileName}";
        await _r2Service.UploadAsync(fileKey, file.OpenReadStream());

        // Get URL
        string downloadUrl = await _r2Service.GetPresignedDownloadUrlAsync(
            fileKey,
            TimeSpan.FromMinutes(30)
        );

        // Create job
        var job = new
        {
            url = downloadUrl,
            targetPath = "/home/ubuntu/uploads",
            filename = file.FileName,
            encrypted = false
        };

        // Get LXD URI
        using var dbContext = await _dbContextFactory.CreateDbContextAsync();
        var instance = await dbContext.Instances
            .Include(i => i.ProviderServer)
            .FirstOrDefaultAsync(i => i.Id == instanceId);

        // Write job file
        string jobFile = $"/tmp/slyd-downloads/job-{Guid.NewGuid()}.json";
        bool success = await _lxdService.PutInstanceFile(
            instance.ProviderServer.LXDUri,
            instanceId.ToString(),
            jobFile,
            JsonSerializer.Serialize(job)
        );

        results.Add(new { filename = file.FileName, success });
    }

    return Ok(new { files = results });
}
```

## Step 4: Testing

### Test on New Instance

1. **Create a new LXD instance** - It will auto-install the watcher
2. **Check service is running:**
   ```bash
   ssh ubuntu@instance
   sudo systemctl status slyd-r2-watcher
   ```

3. **Test file transfer** from platform:
   ```bash
   curl -X POST https://your-platform.com/api/upload/{instanceId} \
     -F "file=@testfile.pdf"
   ```

4. **Verify file arrived:**
   ```bash
   ls -la /home/ubuntu/uploads/
   ```

5. **Check logs:**
   ```bash
   sudo journalctl -u slyd-r2-watcher -n 50
   # or
   tail -f /var/log/slyd-r2-watcher.log
   ```

### Test Auto-Update

1. Update VERSION in GitHub to `1.0.1`
2. Update script in GitHub
3. Wait up to 1 hour (or restart service to force check)
4. Service should auto-update and restart

## Monitoring

### Check Service Status
```bash
systemctl status slyd-r2-watcher
```

### View Logs
```bash
# Real-time
journalctl -u slyd-r2-watcher -f

# Last 100 lines
journalctl -u slyd-r2-watcher -n 100

# Errors only
journalctl -u slyd-r2-watcher -p err
```

### Check Resource Usage
```bash
# CPU and memory
systemctl show slyd-r2-watcher --property=CPUUsageNSec,MemoryCurrent

# Detailed
top -p $(pgrep -f slyd-r2-watcher)
```

## Security Considerations

1. **Presigned URLs** - Use short expiration (15-60 minutes)
2. **Encryption** - Encrypt sensitive files before R2 upload
3. **Job Files** - Automatically cleaned up after processing
4. **GitHub Repo** - Can be private (add auth to curl commands)
5. **Network** - Watcher only downloads from your R2 bucket

## Troubleshooting

### Service not starting
```bash
sudo systemctl status slyd-r2-watcher
sudo journalctl -xe
```

### Downloads failing
- Check R2 URL is accessible from instance
- Verify presigned URL hasn't expired
- Check network connectivity: `curl -I https://r2.domain.com`

### Script not updating
- Check GitHub URL is correct
- Verify VERSION file is accessible
- Force update: `sudo systemctl restart slyd-r2-watcher`

## Cost Analysis

### Resource Usage per Instance
- **CPU:** ~0.5% (5% max limit)
- **Memory:** ~10-20MB (100MB max limit)
- **Storage:** ~100KB (script + logs)
- **Network:** Only during downloads

### At Scale (1000 instances)
- Total CPU overhead: ~5 cores
- Total memory: ~20GB
- Negligible compared to instance workloads

## Next Steps

- [ ] Create GitHub repository
- [ ] Upload scripts
- [ ] Test on development instance
- [ ] Deploy to production
- [ ] Monitor first transfers
- [ ] Document encryption key management
