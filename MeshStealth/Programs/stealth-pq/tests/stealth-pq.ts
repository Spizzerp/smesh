import * as anchor from "@coral-xyz/anchor";
import { Program, BN } from "@coral-xyz/anchor";
import { StealthPq } from "../target/types/stealth_pq";
import { Keypair, LAMPORTS_PER_SOL, PublicKey, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";

describe("stealth-pq", () => {
  // Configure the client to use the local cluster.
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const program = anchor.workspace.stealthPq as Program<StealthPq>;

  // Test constants
  const EPHEMERAL_PUBKEY_SIZE = 32;
  const MLKEM_CIPHERTEXT_SIZE = 1088;
  const CHUNK_SIZE = 512; // Max chunk size per transaction

  // Helper to generate random bytes as Buffer
  function randomBytes(size: number): Buffer {
    const buf = Buffer.alloc(size);
    for (let i = 0; i < size; i++) {
      buf[i] = Math.floor(Math.random() * 256);
    }
    return buf;
  }

  // Helper to derive CiphertextAccount PDA
  function deriveCiphertextPDA(stealthAddress: PublicKey): [PublicKey, number] {
    return PublicKey.findProgramAddressSync(
      [Buffer.from("ciphertext"), stealthAddress.toBuffer()],
      program.programId
    );
  }

  // Helper to perform a complete stealth transfer (init + complete + transfer)
  async function performStealthTransfer(
    stealthKeypair: Keypair,
    ephemeralPubkey: Buffer,
    mlkemCiphertext: Buffer,
    lamports: number
  ): Promise<void> {
    const [ciphertextPDA] = deriveCiphertextPDA(stealthKeypair.publicKey);

    // Split ciphertext into chunks
    const part1 = mlkemCiphertext.slice(0, CHUNK_SIZE);
    const part2 = mlkemCiphertext.slice(CHUNK_SIZE);

    // Step 1: Initialize ciphertext account with first chunk
    await program.methods
      .initCiphertext(Array.from(ephemeralPubkey), Buffer.from(part1))
      .accounts({
        sender: provider.wallet.publicKey,
        stealthAddress: stealthKeypair.publicKey,
        ciphertextAccount: ciphertextPDA,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // Step 2: Complete ciphertext with remaining data
    await program.methods
      .completeCiphertext(Buffer.from(part2), CHUNK_SIZE)
      .accounts({
        sender: provider.wallet.publicKey,
        ciphertextAccount: ciphertextPDA,
      })
      .rpc();

    // Step 3: Transfer SOL if specified
    if (lamports > 0) {
      await program.methods
        .transferToStealth(new BN(lamports))
        .accounts({
          sender: provider.wallet.publicKey,
          stealthAddress: stealthKeypair.publicKey,
          ciphertextAccount: ciphertextPDA,
          systemProgram: SystemProgram.programId,
        })
        .rpc();
    }
  }

  describe("init_ciphertext", () => {
    it("creates ciphertext account with first chunk", async () => {
      const stealthAddress = Keypair.generate();
      const ephemeralPubkey = randomBytes(EPHEMERAL_PUBKEY_SIZE);
      const part1 = randomBytes(CHUNK_SIZE);

      const [ciphertextPDA, bump] = deriveCiphertextPDA(stealthAddress.publicKey);

      const tx = await program.methods
        .initCiphertext(Array.from(ephemeralPubkey), Buffer.from(part1))
        .accounts({
          sender: provider.wallet.publicKey,
          stealthAddress: stealthAddress.publicKey,
          ciphertextAccount: ciphertextPDA,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      console.log("init_ciphertext tx:", tx);

      // Verify account was created
      const ciphertextAccount = await program.account.ciphertextAccount.fetch(ciphertextPDA);

      expect(ciphertextAccount.stealthPubkey.toBase58()).to.equal(stealthAddress.publicKey.toBase58());
      expect(Buffer.from(ciphertextAccount.ephemeralPubkey).equals(ephemeralPubkey)).to.be.true;
      expect(ciphertextAccount.bump).to.equal(bump);
      expect(ciphertextAccount.createdAt.toNumber()).to.be.greaterThan(0);
    });
  });

  describe("complete_ciphertext", () => {
    it("stores remaining ciphertext data", async () => {
      const stealthAddress = Keypair.generate();
      const ephemeralPubkey = randomBytes(EPHEMERAL_PUBKEY_SIZE);
      const fullCiphertext = randomBytes(MLKEM_CIPHERTEXT_SIZE);
      const part1 = fullCiphertext.slice(0, CHUNK_SIZE);
      const part2 = fullCiphertext.slice(CHUNK_SIZE);

      const [ciphertextPDA] = deriveCiphertextPDA(stealthAddress.publicKey);

      // Initialize
      await program.methods
        .initCiphertext(Array.from(ephemeralPubkey), Buffer.from(part1))
        .accounts({
          sender: provider.wallet.publicKey,
          stealthAddress: stealthAddress.publicKey,
          ciphertextAccount: ciphertextPDA,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      // Complete
      const tx = await program.methods
        .completeCiphertext(Buffer.from(part2), CHUNK_SIZE)
        .accounts({
          sender: provider.wallet.publicKey,
          ciphertextAccount: ciphertextPDA,
        })
        .rpc();

      console.log("complete_ciphertext tx:", tx);

      // Verify full ciphertext is stored
      const ciphertextAccount = await program.account.ciphertextAccount.fetch(ciphertextPDA);
      const storedCiphertext = Buffer.from(ciphertextAccount.mlkemCiphertext);

      expect(storedCiphertext.equals(fullCiphertext)).to.be.true;
    });
  });

  describe("transfer_to_stealth", () => {
    it("transfers SOL to stealth address", async () => {
      const stealthKeypair = Keypair.generate();
      const ephemeralPubkey = randomBytes(EPHEMERAL_PUBKEY_SIZE);
      const mlkemCiphertext = randomBytes(MLKEM_CIPHERTEXT_SIZE);
      const lamports = 0.1 * LAMPORTS_PER_SOL;

      const [ciphertextPDA] = deriveCiphertextPDA(stealthKeypair.publicKey);

      // Setup: init and complete ciphertext
      const part1 = mlkemCiphertext.slice(0, CHUNK_SIZE);
      const part2 = mlkemCiphertext.slice(CHUNK_SIZE);

      await program.methods
        .initCiphertext(Array.from(ephemeralPubkey), Buffer.from(part1))
        .accounts({
          sender: provider.wallet.publicKey,
          stealthAddress: stealthKeypair.publicKey,
          ciphertextAccount: ciphertextPDA,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      await program.methods
        .completeCiphertext(Buffer.from(part2), CHUNK_SIZE)
        .accounts({
          sender: provider.wallet.publicKey,
          ciphertextAccount: ciphertextPDA,
        })
        .rpc();

      // Transfer SOL
      const tx = await program.methods
        .transferToStealth(new BN(lamports))
        .accounts({
          sender: provider.wallet.publicKey,
          stealthAddress: stealthKeypair.publicKey,
          ciphertextAccount: ciphertextPDA,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      console.log("transfer_to_stealth tx:", tx);

      // Verify SOL was transferred
      const stealthBalance = await provider.connection.getBalance(stealthKeypair.publicKey);
      expect(stealthBalance).to.equal(lamports);
    });
  });

  describe("reclaim_rent", () => {
    it("closes ciphertext account and returns rent to stealth address", async () => {
      const stealthKeypair = Keypair.generate();
      const ephemeralPubkey = randomBytes(EPHEMERAL_PUBKEY_SIZE);
      const mlkemCiphertext = randomBytes(MLKEM_CIPHERTEXT_SIZE);
      const transferAmount = 0.1 * LAMPORTS_PER_SOL;

      await performStealthTransfer(
        stealthKeypair,
        ephemeralPubkey,
        mlkemCiphertext,
        transferAmount
      );

      const [ciphertextPDA] = deriveCiphertextPDA(stealthKeypair.publicKey);

      // Get balance before reclaim
      const stealthBalanceBefore = await provider.connection.getBalance(stealthKeypair.publicKey);
      const ciphertextRent = await provider.connection.getBalance(ciphertextPDA);

      console.log("Stealth balance before reclaim:", stealthBalanceBefore / LAMPORTS_PER_SOL, "SOL");
      console.log("Ciphertext account rent:", ciphertextRent / LAMPORTS_PER_SOL, "SOL");

      // Reclaim rent
      const tx = await program.methods
        .reclaimRent()
        .accounts({
          stealthSigner: stealthKeypair.publicKey,
          ciphertextAccount: ciphertextPDA,
        })
        .signers([stealthKeypair])
        .rpc();

      console.log("reclaim_rent tx:", tx);

      // Verify ciphertext account was closed
      const ciphertextAccountInfo = await provider.connection.getAccountInfo(ciphertextPDA);
      expect(ciphertextAccountInfo).to.be.null;

      // Verify rent was returned
      const stealthBalanceAfter = await provider.connection.getBalance(stealthKeypair.publicKey);
      console.log("Stealth balance after reclaim:", stealthBalanceAfter / LAMPORTS_PER_SOL, "SOL");

      expect(stealthBalanceAfter).to.be.greaterThan(stealthBalanceBefore);
    });

    it("fails if non-stealth-address tries to reclaim", async () => {
      const stealthKeypair = Keypair.generate();
      const ephemeralPubkey = randomBytes(EPHEMERAL_PUBKEY_SIZE);
      const mlkemCiphertext = randomBytes(MLKEM_CIPHERTEXT_SIZE);

      await performStealthTransfer(stealthKeypair, ephemeralPubkey, mlkemCiphertext, 0);

      const [ciphertextPDA] = deriveCiphertextPDA(stealthKeypair.publicKey);

      // Try to reclaim with a different keypair
      const attacker = Keypair.generate();

      // Airdrop some SOL to attacker
      const airdropSig = await provider.connection.requestAirdrop(
        attacker.publicKey,
        0.1 * LAMPORTS_PER_SOL
      );
      await provider.connection.confirmTransaction(airdropSig);

      try {
        await program.methods
          .reclaimRent()
          .accounts({
            stealthSigner: attacker.publicKey,
            ciphertextAccount: ciphertextPDA,
          })
          .signers([attacker])
          .rpc();

        expect.fail("Expected error for unauthorized reclaim");
      } catch (err: any) {
        expect(err.toString()).to.include("ConstraintSeeds");
      }
    });
  });

  describe("full flow", () => {
    it("complete stealth transfer with ciphertext and SOL", async () => {
      const stealthKeypair = Keypair.generate();
      const ephemeralPubkey = randomBytes(EPHEMERAL_PUBKEY_SIZE);
      const mlkemCiphertext = randomBytes(MLKEM_CIPHERTEXT_SIZE);
      const transferAmount = 0.05 * LAMPORTS_PER_SOL;

      // Perform full transfer
      await performStealthTransfer(
        stealthKeypair,
        ephemeralPubkey,
        mlkemCiphertext,
        transferAmount
      );

      const [ciphertextPDA] = deriveCiphertextPDA(stealthKeypair.publicKey);

      // Verify ciphertext is stored correctly
      const ciphertextAccount = await program.account.ciphertextAccount.fetch(ciphertextPDA);
      expect(Buffer.from(ciphertextAccount.mlkemCiphertext).equals(mlkemCiphertext)).to.be.true;
      expect(Buffer.from(ciphertextAccount.ephemeralPubkey).equals(ephemeralPubkey)).to.be.true;

      // Verify SOL was transferred
      const stealthBalance = await provider.connection.getBalance(stealthKeypair.publicKey);
      expect(stealthBalance).to.equal(transferAmount);

      console.log("Full flow completed successfully!");
    });
  });
});
