#!/usr/bin/env rspec

require 'spec_helper'

firewallchain = Puppet::Type.type(:firewallchain)
firewallchain_ignore = Puppet::Type.type(:firewallchain_ignore)

describe firewallchain do
  before(:each) do
    # Stub confine facts
    allow(Facter.fact(:kernel)).to receive(:value).and_return('Linux')
    allow(Facter.fact(:operatingsystem)).to receive(:value).and_return('Debian')
  end
  let(:klass) { firewallchain }
  let(:provider) {
    prov = double 'provider'
    allow(prov).to receive(:name).and_return(:iptables_chain)
    prov
  }
  let(:resource) {
    allow(Puppet::Type::Firewallchain).to receive(:defaultprovider).and_return provider
    klass.new({:name => 'INPUT:filter:IPv4', :policy => :accept })
  }

  it 'should have :name be its namevar' do
    expect(klass.key_attributes).to eql [:name]
  end

  describe ':name' do
    {'nat' => ['PREROUTING', 'POSTROUTING', 'INPUT', 'OUTPUT'],
     'mangle' => [ 'PREROUTING', 'POSTROUTING', 'INPUT', 'FORWARD', 'OUTPUT' ],
     'filter' => ['INPUT','OUTPUT','FORWARD'],
     'raw' => [ 'PREROUTING', 'OUTPUT'],
     'broute' => ['BROUTING'],
     'security' => ['INPUT','OUTPUT','FORWARD']
    }.each_pair do |table, allowedinternalchains|
      ['IPv4', 'IPv6', 'ethernet'].each do |protocol|
        [ 'test', '$5()*&%\'"^$09):' ].each do |chainname|
          name = "#{chainname}:#{table}:#{protocol}"
          if table == 'nat' && protocol == 'IPv6'
            it "should accept #{name} for Linux 3.7+" do
              allow(Facter.fact(:kernelmajversion)).to receive(:value).and_return('3.7')
              resource[:name] = name
              expect(resource[:name]).to eql name
            end
            it "should fail #{name} for Linux 2.6" do
              allow(Facter.fact(:kernelmajversion)).to receive(:value).and_return('2.6')
              expect { resource[:name] = name }.to raise_error(Puppet::Error)
            end
          elsif protocol != 'ethernet' && table == 'broute'
            it "should fail #{name}" do
              expect { resource[:name] = name }.to raise_error(Puppet::Error)
            end
          else
            it "should accept name #{name}" do
              resource[:name] = name
              expect(resource[:name]).to eql name
            end
          end
        end # chainname
      end # protocol

      [ 'PREROUTING', 'POSTROUTING', 'BROUTING', 'INPUT', 'FORWARD', 'OUTPUT' ].each do |internalchain|
        name = internalchain + ':' + table + ':'
        if internalchain == 'BROUTING'
          name += 'ethernet'
        elsif table == 'nat'
          name += 'IPv4'
        else
          name += 'IPv4'
        end
        if allowedinternalchains.include? internalchain
          it "should allow #{name}" do
            resource[:name] = name
            expect(resource[:name]).to eql name
          end
        else
          it "should fail #{name}" do
            expect { resource[:name] = name }.to raise_error(Puppet::Error)
          end
        end
      end # internalchain

    end # table, allowedinternalchainnames

    it 'should fail with invalid table names' do
      expect { resource[:name] = 'wrongtablename:test:IPv4' }.to raise_error(Puppet::Error)
    end

    it 'should fail with invalid protocols names' do
      expect { resource[:name] = 'test:filter:IPv5' }.to raise_error(Puppet::Error)
    end

  end

  describe ':policy' do

    [:accept, :drop, :queue, :return].each do |policy|
      it "should accept policy #{policy}" do
        resource[:policy] = policy
        expect(resource[:policy]).to eql policy
      end
    end

    it 'should fail when value is not recognized' do
      expect { resource[:policy] = 'not valid' }.to raise_error(Puppet::Error)
    end

    [:accept, :drop, :queue, :return].each do |policy|
      it "non-inbuilt chains should not accept policy #{policy}" do
        expect { klass.new({:name => 'testchain:filter:IPv4', :policy => policy }) }.to raise_error(Puppet::Error)
      end
      it "non-inbuilt chains can accept policies on protocol = ethernet (policy #{policy})" do
        klass.new({:name => 'testchain:filter:ethernet', :policy => policy })
      end
    end

  end

  describe 'autorequire packages' do
    it "provider iptables_chain should autorequire package iptables" do
      expect(resource[:provider]).to eql :iptables_chain
      package = Puppet::Type.type(:package).new(:name => 'iptables')
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource resource
      catalog.add_resource package
      rel = resource.autorequire[0]
      expect(rel.source.ref).to eql package.ref
      expect(rel.target.ref).to eql resource.ref
    end

    it "provider iptables_chain should autorequire packages iptables, iptables-persistent, and iptables-services" do
      expect(resource[:provider]).to eql :iptables_chain
      packages = [
        Puppet::Type.type(:package).new(:name => 'iptables'),
        Puppet::Type.type(:package).new(:name => 'iptables-persistent'),
        Puppet::Type.type(:package).new(:name => 'iptables-services')
      ]
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource resource
      packages.each do |package|
        catalog.add_resource package
      end
      packages.zip(resource.autorequire) do |package, rel|
        expect(rel.source.ref).to eql package.ref
        expect(rel.target.ref).to eql resource.ref
      end
    end
  end

  describe 'purge iptables rules' do
    before(:each) do
      stub_return = <<EOS
# Completed on Sun Jan  5 19:30:21 2014
# Generated by iptables-save v1.4.12 on Sun Jan  5 19:30:21 2014
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:LOCAL_FORWARD - [0:0]
:LOCAL_FORWARD_PRE - [0:0]
:LOCAL_INPUT - [0:0]
:LOCAL_INPUT_PRE - [0:0]
:fail2ban-ssh - [0:0]
-A INPUT -p tcp -m multiport --dports 22 -j fail2ban-ssh
-A INPUT -p tcp -m multiport --dports 22 -j fail2ban-postfix
-A INPUT -i lo -m comment --comment "012 accept loopback" -j ACCEPT
-A INPUT -p tcp -m multiport --dports 22 -m comment --comment "020 ssh" -j ACCEPT
-A OUTPUT -d 1.2.1.2 -j DROP
-A fail2ban-ssh -j RETURN
COMMIT
# Completed on Sun Jan  5 19:30:21 2014
EOS
      allow(Puppet::Type.type(:firewall).provider(:iptables)).to receive(:iptables_save).and_return(stub_return)
      allow(Puppet::Type.type(:firewall).provider(:ip6tables)).to receive(:ip6tables_save).and_return(stub_return)
    end

    it 'should generate iptables resources' do
      allow(Facter.fact(:ip6tables_version)).to receive(:value).and_return("1.4.21")
      resource = Puppet::Type::Firewallchain.new(:name => 'INPUT:filter:IPv4', :purge => true)
      
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource resource
      
      expect(resource.generate.size).to eq(4)
    end

    it 'should not generate ignored iptables rules' do
      allow(Facter.fact(:ip6tables_version)).to receive(:value).and_return("1.4.21")
      resource = Puppet::Type::Firewallchain.new(:name => 'INPUT:filter:IPv4', :purge => true, :ignore => ['-j fail2ban-ssh'])
      ignored = Puppet::Type.type(:firewallchain_ignore).new(:name => 'ignored', :regex => ['-j fail2ban-postfix'], :chain => 'INPUT:filter:IPv4')
        
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource resource
      catalog.add_resource ignored

      expect(resource.generate.size).to eq(2)
    end

    it 'should not generate iptables resources when not enabled' do
      resource = Puppet::Type::Firewallchain.new(:name => 'INPUT:filter:IPv4')

      expect(resource.generate.size).to eq(0)
    end
  end
  it 'is suitable' do
    expect(resource.suitable?).to be_truthy
  end
end

describe 'firewall on unsupported platforms' do
  it 'is not suitable' do
    # Stub iptables version
    allow(Facter.fact(:iptables_version)).to receive(:value).and_return(nil)
    allow(Facter.fact(:ip6tables_version)).to receive(:value).and_return(nil)

    # Stub confine facts
    allow(Facter.fact(:kernel)).to receive(:value).and_return('Darwin')
    allow(Facter.fact(:operatingsystem)).to receive(:value).and_return('Darwin')
    resource = firewallchain.new(:name => "INPUT:filter:IPv4", :ensure => :present)

    # If our provider list is nil, then the Puppet::Transaction#evaluate will
    # say 'Error: Could not find a suitable provider for firewall' but there
    # isn't a unit testable way to get this.
    expect(resource.suitable?).to be_falsey
  end
end
