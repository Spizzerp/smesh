use anchor_lang::prelude::*;
use anchor_lang::system_program;

declare_id!("5YXYyH7i9WnQz1Hzh8kEuxSU5ws3n1Kor2KdTxnJkv6y");

/// MLKEM768 ciphertext size in bytes
pub const MLKEM_CIPHERTEXT_SIZE: usize = 1088;

/// X25519 ephemeral public key size in bytes
pub const EPHEMERAL_PUBKEY_SIZE: usize = 32;

#[program]
pub mod stealth_pq {
    use super::*;

    /// Initialize the CiphertextAccount PDA with metadata.
    /// Due to Solana transaction size limits (~1232 bytes), ciphertext storage
    /// is split into two phases:
    /// 1. init_ciphertext: Creates the PDA and stores ephemeral key + first chunk
    /// 2. complete_ciphertext: Stores the remaining ciphertext data
    ///
    /// # Arguments
    /// * `ephemeral_pubkey` - X25519 ephemeral public key (R) used for ECDH
    /// * `ciphertext_part1` - First 512 bytes of MLKEM768 ciphertext
    pub fn init_ciphertext(
        ctx: Context<StealthTransfer>,
        ephemeral_pubkey: [u8; EPHEMERAL_PUBKEY_SIZE],
        ciphertext_part1: Vec<u8>,
    ) -> Result<()> {
        require!(
            ciphertext_part1.len() <= 512,
            StealthError::InvalidCiphertextLength
        );

        let ciphertext_account = &mut ctx.accounts.ciphertext_account;
        ciphertext_account.stealth_pubkey = ctx.accounts.stealth_address.key();
        ciphertext_account.ephemeral_pubkey = ephemeral_pubkey;
        ciphertext_account.mlkem_ciphertext[..ciphertext_part1.len()]
            .copy_from_slice(&ciphertext_part1);
        ciphertext_account.created_at = Clock::get()?.unix_timestamp;
        ciphertext_account.bump = ctx.bumps.ciphertext_account;

        msg!(
            "Initialized ciphertext for stealth address: {}",
            ctx.accounts.stealth_address.key()
        );

        Ok(())
    }

    /// Complete ciphertext storage with remaining data.
    ///
    /// # Arguments
    /// * `ciphertext_part2` - Remaining bytes of MLKEM768 ciphertext (up to 576 bytes)
    /// * `offset` - Offset in the ciphertext array to write to
    pub fn complete_ciphertext(
        ctx: Context<CompleteCiphertext>,
        ciphertext_part2: Vec<u8>,
        offset: u16,
    ) -> Result<()> {
        require!(
            (offset as usize) + ciphertext_part2.len() <= MLKEM_CIPHERTEXT_SIZE,
            StealthError::InvalidCiphertextLength
        );

        let ciphertext_account = &mut ctx.accounts.ciphertext_account;
        let start = offset as usize;
        let end = start + ciphertext_part2.len();
        ciphertext_account.mlkem_ciphertext[start..end].copy_from_slice(&ciphertext_part2);

        msg!("Completed ciphertext at offset {}", offset);

        Ok(())
    }

    /// Transfer SOL to a stealth address that has a ciphertext account.
    ///
    /// # Arguments
    /// * `lamports` - Amount of SOL to transfer
    pub fn transfer_to_stealth(ctx: Context<TransferToStealth>, lamports: u64) -> Result<()> {
        require!(lamports > 0, StealthError::ZeroTransferAmount);

        system_program::transfer(
            CpiContext::new(
                ctx.accounts.system_program.to_account_info(),
                system_program::Transfer {
                    from: ctx.accounts.sender.to_account_info(),
                    to: ctx.accounts.stealth_address.to_account_info(),
                },
            ),
            lamports,
        )?;

        msg!(
            "Transferred {} lamports to stealth address: {}",
            lamports,
            ctx.accounts.stealth_address.key()
        );

        Ok(())
    }

    /// Reclaim rent by closing the CiphertextAccount PDA.
    ///
    /// Only the stealth address owner (who has the derived spending key) can call this.
    /// The rent is returned to the stealth address (the signer).
    ///
    /// This should be called when the recipient is spending from the stealth address,
    /// as they no longer need the ciphertext data.
    pub fn reclaim_rent(_ctx: Context<ReclaimRent>) -> Result<()> {
        // Account closure and rent return is handled automatically by Anchor's `close` constraint
        msg!("Ciphertext account closed, rent reclaimed");
        Ok(())
    }
}

/// PDA storing MLKEM768 ciphertext for a hybrid stealth transfer.
///
/// Seeds: ["ciphertext", stealth_pubkey]
///
/// This account is created by the sender when making a stealth transfer,
/// and closed by the recipient when they spend from the stealth address.
#[account]
pub struct CiphertextAccount {
    /// The stealth address this ciphertext is for (32 bytes)
    pub stealth_pubkey: Pubkey,

    /// Ephemeral X25519 public key (R) used for ECDH shared secret (32 bytes)
    pub ephemeral_pubkey: [u8; EPHEMERAL_PUBKEY_SIZE],

    /// MLKEM768 ciphertext from encapsulation (1088 bytes)
    pub mlkem_ciphertext: [u8; MLKEM_CIPHERTEXT_SIZE],

    /// Unix timestamp when the transfer was created (8 bytes)
    pub created_at: i64,

    /// Bump seed for PDA derivation (1 byte)
    pub bump: u8,
}

impl Default for CiphertextAccount {
    fn default() -> Self {
        Self {
            stealth_pubkey: Pubkey::default(),
            ephemeral_pubkey: [0u8; EPHEMERAL_PUBKEY_SIZE],
            mlkem_ciphertext: [0u8; MLKEM_CIPHERTEXT_SIZE],
            created_at: 0,
            bump: 0,
        }
    }
}

impl CiphertextAccount {
    /// Size of CiphertextAccount in bytes (without Anchor discriminator)
    /// 32 (pubkey) + 32 (ephemeral) + 1088 (ciphertext) + 8 (timestamp) + 1 (bump) = 1161
    pub const SIZE: usize = 32 + EPHEMERAL_PUBKEY_SIZE + MLKEM_CIPHERTEXT_SIZE + 8 + 1;
}

/// Accounts for the stealth_transfer instruction.
///
/// Creates a CiphertextAccount PDA and optionally transfers SOL.
#[derive(Accounts)]
pub struct StealthTransfer<'info> {
    /// The sender who pays for the transaction and rent
    #[account(mut)]
    pub sender: Signer<'info>,

    /// The one-time stealth address that will receive funds.
    /// CHECK: This is a derived stealth address, not an existing account.
    /// It's intentionally unchecked as it's a fresh address for this transfer.
    #[account(mut)]
    pub stealth_address: AccountInfo<'info>,

    /// PDA storing the MLKEM ciphertext, derived from the stealth address.
    /// Sender pays rent for this account.
    #[account(
        init,
        payer = sender,
        space = 8 + CiphertextAccount::SIZE,
        seeds = [b"ciphertext", stealth_address.key().as_ref()],
        bump
    )]
    pub ciphertext_account: Account<'info, CiphertextAccount>,

    /// System program for account creation and SOL transfers
    pub system_program: Program<'info, System>,
}

/// Accounts for completing ciphertext storage.
#[derive(Accounts)]
pub struct CompleteCiphertext<'info> {
    /// The sender who initiated the transfer
    #[account(mut)]
    pub sender: Signer<'info>,

    /// The existing CiphertextAccount PDA
    #[account(
        mut,
        seeds = [b"ciphertext", ciphertext_account.stealth_pubkey.as_ref()],
        bump = ciphertext_account.bump,
    )]
    pub ciphertext_account: Account<'info, CiphertextAccount>,
}

/// Accounts for transferring SOL to a stealth address.
#[derive(Accounts)]
pub struct TransferToStealth<'info> {
    /// The sender who pays for the transfer
    #[account(mut)]
    pub sender: Signer<'info>,

    /// The stealth address receiving the SOL.
    /// CHECK: Unchecked as it's a derived stealth address.
    #[account(mut)]
    pub stealth_address: AccountInfo<'info>,

    /// Verify the ciphertext account exists for this stealth address
    #[account(
        seeds = [b"ciphertext", stealth_address.key().as_ref()],
        bump = ciphertext_account.bump,
    )]
    pub ciphertext_account: Account<'info, CiphertextAccount>,

    /// System program for SOL transfer
    pub system_program: Program<'info, System>,
}

/// Accounts for the reclaim_rent instruction.
///
/// Closes the CiphertextAccount and returns rent to the stealth address.
#[derive(Accounts)]
pub struct ReclaimRent<'info> {
    /// The stealth address owner (must be the signer).
    /// This proves they have the derived spending key.
    /// Rent is returned to this account.
    #[account(mut)]
    pub stealth_signer: Signer<'info>,

    /// The CiphertextAccount to close.
    /// Must belong to this stealth address (verified by seeds).
    #[account(
        mut,
        close = stealth_signer,
        seeds = [b"ciphertext", stealth_signer.key().as_ref()],
        bump = ciphertext_account.bump,
    )]
    pub ciphertext_account: Account<'info, CiphertextAccount>,
}

/// Custom errors for the stealth-pq program
#[error_code]
pub enum StealthError {
    #[msg("Invalid ciphertext length or offset.")]
    InvalidCiphertextLength,

    #[msg("Transfer amount must be greater than zero.")]
    ZeroTransferAmount,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ciphertext_account_size() {
        // Verify our size calculation is correct
        assert_eq!(CiphertextAccount::SIZE, 1161);

        // With Anchor discriminator (8 bytes), total space needed
        assert_eq!(8 + CiphertextAccount::SIZE, 1169);
    }
}
