"use client";

import { useMemo, useState } from "react";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatEther, parseEther } from "viem";
import { erc20Abi } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { useDeployedContractInfo, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

type Tab = "deposit" | "withdraw" | "stake" | "rewards";

const Home: NextPage = () => {
  const { address } = useAccount();
  const [tab, setTab] = useState<Tab>("deposit");

  return (
    <div className="flex flex-col grow w-full">
      <Hero />
      <StatsBar />
      <div className="max-w-5xl w-full mx-auto px-4 py-10 flex flex-col gap-8 grow">
        {address ? <UserPosition address={address} /> : null}

        <div className="card bg-base-100 shadow-xl border border-base-300">
          <div className="tabs tabs-boxed bg-base-200 rounded-t-xl rounded-b-none justify-center p-2">
            <TabButton current={tab} me="deposit" onClick={setTab}>
              Deposit
            </TabButton>
            <TabButton current={tab} me="withdraw" onClick={setTab}>
              Withdraw
            </TabButton>
            <TabButton current={tab} me="stake" onClick={setTab}>
              Stake
            </TabButton>
            <TabButton current={tab} me="rewards" onClick={setTab}>
              Rewards
            </TabButton>
          </div>
          <div className="card-body">
            {tab === "deposit" && <DepositPanel />}
            {tab === "withdraw" && <WithdrawPanel />}
            {tab === "stake" && <StakePanel />}
            {tab === "rewards" && <RewardsPanel />}
          </div>
        </div>
      </div>
    </div>
  );
};

export default Home;

// ---------------- pieces ----------------

const Hero = () => (
  <div className="w-full bg-gradient-to-br from-primary/20 via-base-200 to-secondary/20 border-b border-base-300">
    <div className="max-w-5xl mx-auto px-6 py-16 text-center">
      <h1 className="text-5xl md:text-6xl font-bold tracking-tight">
        <span className="bg-gradient-to-r from-primary to-secondary bg-clip-text text-transparent">clawdETH</span>
      </h1>
      <p className="text-xl mt-4 max-w-2xl mx-auto opacity-80">
        ETH liquid staking with CLAWD-redirected yield. Deposit ETH, earn CLAWD rewards, fuel deflationary buybacks.
      </p>
    </div>
  </div>
);

const StatsBar = () => {
  const { data: totalAssets } = useScaffoldReadContract({
    contractName: "ClawdETHVault",
    functionName: "totalAssets",
  });
  const { data: pendingYield } = useScaffoldReadContract({
    contractName: "ClawdETHVault",
    functionName: "pendingYield",
  });
  const { data: totalBurned } = useScaffoldReadContract({
    contractName: "ClawdETHHarvester",
    functionName: "totalBurned",
  });
  const { data: totalDistributed } = useScaffoldReadContract({
    contractName: "ClawdETHHarvester",
    functionName: "totalDistributed",
  });

  const stats = [
    { label: "TVL", value: formatEth(totalAssets), unit: "ETH" },
    { label: "Pending Yield", value: formatEth(pendingYield), unit: "ETH" },
    { label: "CLAWD Burned", value: formatEth(totalBurned), unit: "CLAWD" },
    { label: "CLAWD Distributed", value: formatEth(totalDistributed), unit: "CLAWD" },
  ];

  return (
    <div className="border-b border-base-300 bg-base-200/50">
      <div className="max-w-5xl mx-auto px-4 py-6 grid grid-cols-2 md:grid-cols-4 gap-4">
        {stats.map(s => (
          <div key={s.label} className="text-center">
            <div className="text-xs uppercase opacity-60 tracking-wider">{s.label}</div>
            <div className="text-2xl font-bold font-mono mt-1">{s.value}</div>
            <div className="text-xs opacity-60">{s.unit}</div>
          </div>
        ))}
      </div>
    </div>
  );
};

const UserPosition = ({ address }: { address: string }) => {
  const { data: shares } = useScaffoldReadContract({
    contractName: "ClawdETHVault",
    functionName: "balanceOf",
    args: [address],
  });
  const { data: assetValue } = useScaffoldReadContract({
    contractName: "ClawdETHVault",
    functionName: "convertToAssets",
    args: [shares ?? 0n],
  });
  const { data: staked } = useScaffoldReadContract({
    contractName: "ClawdETHRewards",
    functionName: "balanceOf",
    args: [address],
  });
  const { data: earned } = useScaffoldReadContract({
    contractName: "ClawdETHRewards",
    functionName: "earned",
    args: [address],
  });

  return (
    <div className="card bg-base-100 shadow-md border border-base-300">
      <div className="card-body">
        <div className="flex items-center justify-between flex-wrap gap-2">
          <h2 className="card-title">Your Position</h2>
          <Address address={address} />
        </div>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mt-2">
          <Stat label="clawdETH" value={formatEth(assetValue)} hint="ETH value" />
          <Stat label="Staked" value={formatEth(staked)} hint="clawdETH shares" isRaw />
          <Stat label="Claimable" value={formatEth(earned)} hint="CLAWD" />
          <Stat label="Shares" value={formatEth(shares)} hint="clawdETH" isRaw />
        </div>
      </div>
    </div>
  );
};

const Stat = ({ label, value, hint }: { label: string; value: string; hint: string; isRaw?: boolean }) => (
  <div>
    <div className="text-xs opacity-60 uppercase tracking-wider">{label}</div>
    <div className="text-lg font-bold font-mono">{value}</div>
    <div className="text-xs opacity-60">{hint}</div>
  </div>
);

const TabButton = ({
  current,
  me,
  onClick,
  children,
}: {
  current: Tab;
  me: Tab;
  onClick: (t: Tab) => void;
  children: React.ReactNode;
}) => (
  <button
    className={`tab ${current === me ? "tab-active bg-primary text-primary-content" : ""}`}
    onClick={() => onClick(me)}
  >
    {children}
  </button>
);

// ---------------- panels ----------------

const DepositPanel = () => {
  const { address } = useAccount();
  const [amount, setAmount] = useState("");
  const { writeContractAsync, isPending } = useScaffoldWriteContract({
    contractName: "ClawdETHVault",
  });

  const onDeposit = async () => {
    if (!address) return notification.error("Connect wallet");
    if (!amount || Number(amount) <= 0) return notification.error("Enter an amount");
    try {
      await writeContractAsync({
        functionName: "depositETH",
        args: [address],
        value: parseEther(amount),
      });
      setAmount("");
    } catch {
      // write hook already surfaces errors
    }
  };

  return (
    <div className="flex flex-col gap-4">
      <div>
        <label className="label">
          <span className="label-text">Deposit ETH</span>
        </label>
        <input
          type="number"
          step="0.0001"
          min="0"
          placeholder="0.0"
          className="input input-bordered w-full text-lg font-mono"
          value={amount}
          onChange={e => setAmount(e.target.value)}
        />
        <div className="text-xs opacity-60 mt-1">
          You will receive clawdETH shares representing your ETH principal. Yield is redirected to CLAWD buybacks.
        </div>
      </div>
      <button className="btn btn-primary" onClick={onDeposit} disabled={isPending || !address}>
        {isPending ? <span className="loading loading-spinner" /> : "Deposit ETH"}
      </button>
    </div>
  );
};

const WithdrawPanel = () => {
  const { address } = useAccount();
  const [amount, setAmount] = useState("");
  const { data: shares } = useScaffoldReadContract({
    contractName: "ClawdETHVault",
    functionName: "balanceOf",
    args: [address],
  });
  const { data: maxAssets } = useScaffoldReadContract({
    contractName: "ClawdETHVault",
    functionName: "convertToAssets",
    args: [shares ?? 0n],
  });

  const { writeContractAsync, isPending } = useScaffoldWriteContract({
    contractName: "ClawdETHVault",
  });

  const onWithdraw = async () => {
    if (!address) return notification.error("Connect wallet");
    if (!amount || Number(amount) <= 0) return notification.error("Enter an amount");
    try {
      await writeContractAsync({
        functionName: "withdraw",
        args: [parseEther(amount), address, address],
      });
      setAmount("");
    } catch {}
  };

  return (
    <div className="flex flex-col gap-4">
      <div>
        <div className="flex justify-between items-center">
          <label className="label-text">Redeem (WETH out)</label>
          <button className="text-xs link" onClick={() => maxAssets && setAmount(formatEther(maxAssets))}>
            MAX: {formatEth(maxAssets)} ETH
          </button>
        </div>
        <input
          type="number"
          step="0.0001"
          min="0"
          placeholder="0.0"
          className="input input-bordered w-full text-lg font-mono"
          value={amount}
          onChange={e => setAmount(e.target.value)}
        />
      </div>
      <button className="btn btn-primary" onClick={onWithdraw} disabled={isPending || !address}>
        {isPending ? <span className="loading loading-spinner" /> : "Withdraw"}
      </button>
    </div>
  );
};

const StakePanel = () => {
  const { address } = useAccount();
  const [amount, setAmount] = useState("");
  const { data: rewardsInfo } = useDeployedContractInfo({ contractName: "ClawdETHRewards" });
  const { data: vaultInfo } = useDeployedContractInfo({ contractName: "ClawdETHVault" });

  const { data: shares } = useScaffoldReadContract({
    contractName: "ClawdETHVault",
    functionName: "balanceOf",
    args: [address],
  });
  const { data: staked } = useScaffoldReadContract({
    contractName: "ClawdETHRewards",
    functionName: "balanceOf",
    args: [address],
  });
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    abi: erc20Abi,
    address: vaultInfo?.address,
    functionName: "allowance",
    args: address && rewardsInfo?.address ? [address, rewardsInfo.address] : undefined,
  });

  const parsed = useMemo(() => {
    try {
      return amount ? parseEther(amount) : 0n;
    } catch {
      return 0n;
    }
  }, [amount]);

  const needsApproval = parsed > 0n && (allowance ?? 0n) < parsed;

  const { writeContractAsync: approve, isPending: approving } = useScaffoldWriteContract({
    contractName: "ClawdETHVault",
  });
  const { writeContractAsync: stakeFn, isPending: staking } = useScaffoldWriteContract({
    contractName: "ClawdETHRewards",
  });
  const { writeContractAsync: unstakeFn, isPending: unstaking } = useScaffoldWriteContract({
    contractName: "ClawdETHRewards",
  });

  const onApprove = async () => {
    if (!rewardsInfo?.address) return;
    try {
      await approve({
        functionName: "approve",
        args: [rewardsInfo.address, parsed],
      });
      await refetchAllowance();
    } catch {}
  };

  const onStake = async () => {
    if (parsed === 0n) return notification.error("Enter an amount");
    try {
      await stakeFn({ functionName: "stake", args: [parsed] });
      setAmount("");
    } catch {}
  };

  const onUnstake = async () => {
    if (parsed === 0n) return notification.error("Enter an amount");
    try {
      await unstakeFn({ functionName: "withdraw", args: [parsed] });
      setAmount("");
    } catch {}
  };

  return (
    <div className="flex flex-col gap-4">
      <div className="grid grid-cols-2 gap-4 text-sm">
        <div className="p-3 rounded-lg bg-base-200">
          <div className="opacity-60 text-xs uppercase">Unstaked</div>
          <div className="font-mono font-bold">{formatEth(shares)}</div>
        </div>
        <div className="p-3 rounded-lg bg-base-200">
          <div className="opacity-60 text-xs uppercase">Staked</div>
          <div className="font-mono font-bold">{formatEth(staked)}</div>
        </div>
      </div>
      <input
        type="number"
        step="0.0001"
        min="0"
        placeholder="amount of clawdETH"
        className="input input-bordered w-full text-lg font-mono"
        value={amount}
        onChange={e => setAmount(e.target.value)}
      />
      <div className="grid grid-cols-2 gap-2">
        {needsApproval ? (
          <button className="btn btn-secondary col-span-2" onClick={onApprove} disabled={approving || !address}>
            {approving ? <span className="loading loading-spinner" /> : "Approve"}
          </button>
        ) : (
          <button className="btn btn-primary" onClick={onStake} disabled={staking || !address}>
            {staking ? <span className="loading loading-spinner" /> : "Stake"}
          </button>
        )}
        <button
          className={`btn btn-outline ${needsApproval ? "hidden" : ""}`}
          onClick={onUnstake}
          disabled={unstaking || !address}
        >
          {unstaking ? <span className="loading loading-spinner" /> : "Unstake"}
        </button>
      </div>
      <p className="text-xs opacity-60">
        Stake your clawdETH shares to earn CLAWD rewards from harvested yield. Synthetix StakingRewards pattern —
        proportional to your share of total staked.
      </p>
    </div>
  );
};

const RewardsPanel = () => {
  const { address } = useAccount();
  const { data: earned } = useScaffoldReadContract({
    contractName: "ClawdETHRewards",
    functionName: "earned",
    args: [address],
  });
  const { data: rewardRate } = useScaffoldReadContract({
    contractName: "ClawdETHRewards",
    functionName: "rewardRate",
  });
  const { data: periodFinish } = useScaffoldReadContract({
    contractName: "ClawdETHRewards",
    functionName: "periodFinish",
  });

  const { writeContractAsync, isPending } = useScaffoldWriteContract({
    contractName: "ClawdETHRewards",
  });

  const onClaim = async () => {
    try {
      await writeContractAsync({ functionName: "getReward" });
    } catch {}
  };

  const periodEnd = periodFinish ? new Date(Number(periodFinish) * 1000) : null;
  const active = periodEnd && periodEnd.getTime() > Date.now();

  return (
    <div className="flex flex-col gap-4">
      <div className="stats bg-base-200 shadow">
        <div className="stat">
          <div className="stat-title">Claimable CLAWD</div>
          <div className="stat-value font-mono text-primary">{formatEth(earned)}</div>
        </div>
        <div className="stat">
          <div className="stat-title">Reward Rate</div>
          <div className="stat-value text-sm font-mono">{rewardRate ? `${formatEth(rewardRate)}/sec` : "–"}</div>
          <div className="stat-desc">
            {active && periodEnd ? `Until ${periodEnd.toLocaleString()}` : "No active period"}
          </div>
        </div>
      </div>
      <button
        className="btn btn-primary"
        onClick={onClaim}
        disabled={isPending || !address || !earned || earned === 0n}
      >
        {isPending ? <span className="loading loading-spinner" /> : "Claim CLAWD"}
      </button>
    </div>
  );
};

// ---------------- helpers ----------------

function formatEth(v: bigint | undefined) {
  if (v === undefined) return "–";
  const s = formatEther(v);
  const n = Number(s);
  if (n === 0) return "0";
  if (n < 0.0001) return "<0.0001";
  return n.toLocaleString(undefined, { maximumFractionDigits: 4 });
}
