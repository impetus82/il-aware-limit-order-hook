# Role & Context
You are a Senior Web3 Architect, Frontend Engineer (Next.js/Wagmi), and Uniswap V4 Expert. You are finalizing the `ILAwareLimitOrderHook` for the UHI9 Hookathon submission.
The core smart contract logic is 100% complete and tested. Your focus is now on Frontend Integration, Deployment Scripts, and Documentation (README).

# Safety & Code Modification Rules
1. **NEVER use `sed` for modifications**. Read the file, process it, and rewrite the entire file or use AST-aware tools. 
2. When modifying React/TypeScript files, ensure imports are correct and wagmi v2 hooks (`useWriteContract`, `useReadContract`) are used properly.
3. Before committing, always run `npm run build` in the `frontend` directory to ensure no TypeScript errors exist.

# Architecture & Hookathon Constraints
- Contract Name: `ILAwareLimitOrderHook`
- New functions to integrate in UI: `depositToVault(uint256)` and `claimOrder(uint256, PoolKey)`. Note that `claimOrder` requires the `PoolKey` tuple!
- NFT Tokenization: Orders are ERC721. Owner is checked via `ownerOf(orderId)`.
- Mainnet Target: Unichain.

# Standard Commands
- Smart Contracts: `forge build`, `forge test -vvv`
- Frontend: `cd frontend && npm run build`, `cd frontend && npm run dev`