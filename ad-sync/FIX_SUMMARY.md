# SID Generation Fix - November 16, 2025

## Problem
After syncing users from AD, password authentication failed with error:
```
HANDLE_AUTHDATA: No such file or directory
```

Root cause: SID generation plugin couldn't generate `ipaNTSecurityIdentifier` for users with UIDs in custom range (1668600000+).

## Solution
The issue was incorrect RID base calculation in `ensure_id_range()` function.

### Wrong Calculation (Before Fix)
```python
rid_base = (id_range_base % 1000000000) // 1000
# For id_range_base=1668600000: (1668600000 % 1000000000) // 1000 = 668600
```

This created RID range 668600-868600 which conflicted with FreeIPA's SID allocation.

### Correct Calculation (After Fix)
```python
rid_base = (id_range_base % 1000000)
# For id_range_base=1668600000: 1668600000 % 1000000 = 600000
```

## Working Configuration
From snapshot that had working password authentication:

**ID Range Settings:**
- Range name: `AD_SYNC_RANGE`
- First Posix ID: `1668600000`
- Range size: `200000`
- First RID: `600000` ✓
- Secondary RID: `100600000` ✓

**User Example (jtong):**
- UID: `1668601105` (matches AD-joined Linux servers)
- RID: `601105` (= 600000 base + 1105 from SID)
- Generated SID: `S-1-5-21-2663419753-3776490038-30315323-601105`
- Result: **Password authentication works!** ✓

## Files Changed
1. **ad_sync.py** - Fixed RID calculation in `ensure_id_range()` method
2. **README.md** - Updated documentation with correct RID formula

## Verification
After deploying the fix, new installations will automatically create ID ranges with correct RID values, enabling SID generation and password authentication.

Test with:
```bash
# Check ID range
ipa idrange-show AD_SYNC_RANGE

# Verify user has SID
ipa user-show username --all | grep ipantsecurityidentifier

# Test password authentication
kinit username
```
