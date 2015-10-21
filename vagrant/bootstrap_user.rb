class Vagrant::BoostrapUser
  def initialize(vm, remote_user: ENV['ANSIBLE_REMOTE_USER'])
    raise "You need to set ANSIBLE_REMOTE_USER in your shell" unless remote_user

    @vm          = vm
    @remote_user = remote_user

    # Add user #{remote_user} to group wheel
    @create_user = <<-SCRIPT
    useradd -m -s /bin/bash -U #{remote_user}
    groupadd -f #{remote_user}
    usermod -a -s /bin/bash -g #{remote_user} -G wheel #{remote_user}
    SCRIPT

    # Enable wheel group in sudoers
    @enable_wheel = <<-SCRIPT
    sed -i -e "s/^# %wheel/%wheel/" /etc/sudoers
    SCRIPT

    # Set local id_rsa.pub as authorized_key for remote_user
    @add_authorized_key = <<-SCRIPT
    rm -f /home/#{remote_user}/.ssh/authorized_keys
    mkdir -p /home/#{remote_user}/.ssh
    cp /home/vagrant/host_pubkey /home/#{remote_user}/.ssh/authorized_keys
    chown #{remote_user}:#{remote_user} /home/#{remote_user}/.ssh/authorized_keys
    chmod 600 /home/#{remote_user}/.ssh/authorized_keys
    SCRIPT

    # Remove local id_rsa.pub from image
    @remove_host_pubkey = <<-SCRIPT
    rm -f /home/vagrant/host_pubkey
    echo "id_rsa.pub installed for user #{remote_user}"
    SCRIPT
  end

  def perform
    @vm.provision :file, run: 'once', source: '~/.ssh/id_rsa.pub',
      destination: '/home/vagrant/host_pubkey'


    @vm.provision :shell, privileged: true, run: 'once', inline: @create_user
    @vm.provision :shell, privileged: true, run: 'once', inline: @enable_wheel
    @vm.provision :shell, privileged: true, run: 'once', inline: @add_authorized_key
    @vm.provision :shell, privileged: true, run: 'once', inline: @remove_host_pubkey
    self
  end
end
